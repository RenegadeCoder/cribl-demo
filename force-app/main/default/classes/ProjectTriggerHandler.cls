/**
 * ProjectTriggerHandler
 *
 * Trigger handler for Project__c that manages:
 * - Enforcing linear status progression across project stages
 * - Validating required target date fields before leaving Kick Off Call
 * - Stamping stage exit dates
 * - Creating and updating related Tasks as the project moves through stages
 *
 * Security & sharing:
 * - Executes certain DML and queries in system mode intentionally for backend orchestration
 * - For user-context operations prefer WITH USER_MODE or AccessLevel.USER_MODE as appropriate
 *
 * Trigger contexts supported:
 * - before update: validates stage transitions and sets stage-completion date fields
 * - after insert: seeds initial Kick Off Call task for new projects
 *
 * Governor limits:
 * - Bulkified for inserts/updates
 * - Avoids SOQL/DML in uncontrolled loops
 */
public without sharing class ProjectTriggerHandler {
    private static Map<String, String> statusToNextStatusMap = new Map<String, String>{
        'Kick Off Call' => 'Data Collection',
        'Data Collection' => 'Upload Cap Table',
        'Upload Cap Table' => 'Activation',
        'Activation' => 'Complete'
    };
    private static Map<String, String> statusToFieldNameMap = new Map<String, String>{
        'Kick Off Call' => 'Kick_Off_Call_Date__c',
        'Data Collection' => 'Data_Received_Date__c',
        'Upload Cap Table' => 'Cap_Table_Uploaded_Date__c',
        // 'Activation' => 'Activation_Date__c',
        'Activation' => 'Go_Live_Date__c',
        'Complete' => 'Go_Live_Date__c'
    };

    /**
     * Entry point invoked by the Project__c trigger to route to the appropriate context handler.
     *
     * Behavior:
     * - For before update: validates linear status changes, stamps stage exit dates, and prepares Task upserts
     * - For after insert: creates initial Kick Off Call Task for each new Project__c
     *
     * @param newProjects   Trigger.new scope for Project__c
     * @param oldProjectMap Trigger.oldMap scope for Project__c (null on insert)
     */
    public static void executeTrigger(List<Project__c> newProjects, Map<Id, Project__c> oldProjectMap) {
        if (Trigger.isBefore && Trigger.isUpdate) {
            beforeUpdate(newProjects, oldProjectMap);
        } else if (Trigger.isAfter && Trigger.isInsert) {
            afterInsert(newProjects);
        }
    }

    private static void beforeUpdate(List<Project__c> newProjects, Map<Id, Project__c> oldProjectMap) {
        List<Project__c> qualifiedProjects = qualifyProjectsForTaskCreation(newProjects, oldProjectMap);
        if (!qualifiedProjects.isEmpty()) {
            // Handle logic for updated projects
            upsertTasksForUpdatedProjects(qualifiedProjects, oldProjectMap);
        }
    }

    private static void afterInsert(List<Project__c> newProjects) {
        // No qualification needed for this use case, all new Project__c records will need the Tasks created.
        // Future business logic may require qualification, in which case we can add a helper method
        createTasksForNewProjects(newProjects);
    }

    private static Project__c[] qualifyProjectsForTaskCreation(List<Project__c> newProjects, Map<Id, Project__c> oldProjectMap) {
        Project__c[] qualifiedProjects = new List<Project__c>();
        for (Project__c proj : newProjects) {
            Project__c oldProj = oldProjectMap.get(proj.Id);
            if (proj.Project_Status__c != oldProj.Project_Status__c) {
                Boolean isDataValidated = true; // this would only be false if the first stage has incomplete data
                if ('Kick Off Call'.equals(oldProj.Project_Status__c)) {
                    isDataValidated = validateDataCompletion(proj);
                }
                if (statusToNextStatusMap.get(oldProj.Project_Status__c) != proj.Project_Status__c) {
                    proj.Project_Status__c.addError(
                        'Status can only be changed to the next stage in the process: ' +
                        statusToNextStatusMap.get(oldProj.Project_Status__c)
                    );
                    isDataValidated = false; // if the status change is invalid, we should not proceed with task creation even if the data is valid, as this indicates a larger issue with the record update that needs to be resolved first.
                }
                if (isDataValidated) {
                    qualifiedProjects.add(proj);
                }
            }
        }
        return qualifiedProjects;
    }

    // Project cannot move out of the 'Kick Off Call' stage until all required data is completed
    private static Boolean validateDataCompletion(Project__c proj) {
        Boolean dataIsValid = false;
        if (proj.Target_Go_Live_Date__c == null || proj.Target_Go_Live_Date__c < Date.today()) {
            proj.Target_Go_Live_Date__c.addError(
                'Target Go Live Date must be completed and in the future before moving out of Kick Off Call stage.'
            );
        }
        if (proj.Target_Data_Received_Date__c == null || proj.Target_Data_Received_Date__c < Date.today()) {
            proj.Target_Data_Received_Date__c.addError(
                'Target Data Received Date must be completed and in the future before moving out of Kick Off Call stage.'
            );
        }
        if (proj.Target_Cap_Table_Uploaded_Date__c == null || proj.Target_Cap_Table_Uploaded_Date__c < Date.today()) {
            proj.Target_Cap_Table_Uploaded_Date__c.addError(
                'Target Cap Table Uploaded Date must be completed and in the future before moving out of Kick Off Call stage.'
            );
        }
        if (proj.Implementation_Manager__c == null) {
            proj.Implementation_Manager__c.addError(
                'Implementation Manager must be assigned before moving out of Kick Off Call stage.'
            );
        } else {
            dataIsValid = true;
        }
        // may need additional validation to check that no fields get nulled after initial completion, depending on business requirements.
        return dataIsValid;
    }

    private static void upsertTasksForUpdatedProjects(List<Project__c> qualifiedProjects, Map<Id, Project__c> oldProjectMap) {
        List<Task> tasksToUpsert = new List<Task>();
        Set<Id> projectIds = oldProjectMap.keySet();
        Map<Id, Task[]> projectIdToTasksMap = new Map<Id, Task[]>();
        for (Task t : [
            SELECT Id, Subject, WhatId, OwnerId, CompletedDateTime, ActivityDate, Status
            FROM Task
            WHERE WhatId IN :projectIds
            WITH SYSTEM_MODE
        ]) {
            if (!projectIdToTasksMap.containsKey(t.WhatId)) {
                projectIdToTasksMap.put(t.WhatId, new List<Task>());
            }
            projectIdToTasksMap.get(t.WhatId).add(t);
        }

        for (Project__c proj : qualifiedProjects) {
            // Example of using the old vs new values to customize the Task creation logic
            String oldStatus = oldProjectMap.get(proj.Id).Project_Status__c;
            String newStatus = proj.Project_Status__c;
            proj.put(statusToFieldNameMap.get(oldStatus), System.today()); // set the date field for the stage we are moving out of to today
            Task[] existingTasks = projectIdToTasksMap.get(proj.Id);
            for (Task t : existingTasks) {
                if (t.Subject == oldStatus) {
                    t.Status = 'Completed';
                    // t.CompletedDateTime = System.now();
                    tasksToUpsert.add(t);
                } else if (t.Subject == newStatus) {
                    t.Status = 'In Progress';
                    t.OwnerId = proj.Implementation_Manager__c; // example of changing ownership based on project manager when status changes
                    tasksToUpsert.add(t);
                }
            }
            if ('Kick Off Call'.equals(oldStatus)) {
                tasksToUpsert.addAll(
                    new List<Task>{
                        new Task(
                            Subject = 'Data Collection',
                            WhatId = proj.Id,
                            Status = 'In Progress',
                            OwnerId = proj.Implementation_Manager__c,
                            ActivityDate = proj.Target_Data_Received_Date__c
                        ),
                        new Task(
                            Subject = 'Upload Cap Table',
                            WhatId = proj.Id,
                            Status = 'Not Started',
                            OwnerId = proj.Implementation_Manager__c,
                            ActivityDate = proj.Target_Cap_Table_Uploaded_Date__c
                        ),
                        new Task(
                            Subject = 'Activation',
                            WhatId = proj.Id,
                            Status = 'Not Started',
                            OwnerId = proj.Implementation_Manager__c,
                            ActivityDate = proj.Target_Go_Live_Date__c
                        )
                    }
                );
            }
        }
        // system mode used to ensure we can insert tasks regardless of the running user's permissions, as this is a backend
        // process that should not be blocked by sharing rules or profile permissions.
        upsert as system tasksToUpsert;
    }

    private static void createTasksForNewProjects(List<Project__c> newProjects) {
        List<Task> tasksToInsert = new List<Task>();
        for (Project__c proj : newProjects) {
            tasksToInsert.add(
                new Task(
                    Subject = 'Kick Off Call',
                    WhatId = proj.Id,
                    Status = 'Not Started',
                    ActivityDate = Date.today().addDays(7)
                )
            );
        }
        // system mode used to ensure we can insert tasks regardless of the running user's permissions, as this is a backend
        // process that should not be blocked by sharing rules or profile permissions.
        insert as system tasksToInsert;
    }
}
