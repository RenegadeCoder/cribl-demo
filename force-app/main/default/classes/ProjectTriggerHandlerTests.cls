/**
 * ProjectTriggerHandlerTests
 * Unit tests for ProjectTriggerHandler trigger handler.
 *
 * Coverage goals:
 * - After insert: creates initial Kick Off Call Task
 * - Before update happy paths:
 *   - Kick Off Call -> Data Collection
 *   - Data Collection -> Upload Cap Table
 * - Negative/error paths:
 *   - Invalid status jump (Kick Off Call -> Upload Cap Table) addError on Project_Status__c
 *   - Missing/past target dates when leaving Kick Off Call addError on relevant Target_* fields
 * - Bulk updates/insert
 *
 * Best practices:
 * - No SeeAllData
 * - Uses Test.startTest()/Test.stopTest()
 * - Three-parameter assertions with descriptive messages
 * - Minimal test data via @TestSetup
 */
@IsTest
private class ProjectTriggerHandlerTests {
    // Constants for reuse
    private static final String STATUS_KICK_OFF = 'Kick Off Call';
    private static final String STATUS_DATA_COLLECTION = 'Data Collection';
    private static final String STATUS_UPLOAD_CAP = 'Upload Cap Table';
    private static final String STATUS_ACTIVATION = 'Activation';

    @TestSetup
    static void setupData() {
        // Create a simple Account as parent if needed by page layouts/VRs (object allows Activities and parented sharing)
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        // Use running user as Implementation Manager to avoid creating users in tests
        Id runningUserId = UserInfo.getUserId();

        Date today = Date.today();
        Date future7 = today.addDays(7);
        Date future14 = today.addDays(14);
        Date future21 = today.addDays(21);

        // Project A: in Kick Off Call with valid FUTURE target dates (for happy path transition)
        Project__c projA = new Project__c(
            Name = 'Proj A',
            Account__c = acc.Id,
            Project_Status__c = STATUS_KICK_OFF,
            Implementation_Manager__c = runningUserId,
            Target_Go_Live_Date__c = future21,
            Target_Data_Received_Date__c = future14,
            Target_Cap_Table_Uploaded_Date__c = future7
        );
        insert projA;

        // Seed tasks for A to exercise update behavior:
        // - Kick Off Call (current) and Data Collection (next)
        insert new Task(Subject = STATUS_KICK_OFF, WhatId = projA.Id, Status = 'Not Started', ActivityDate = today.addDays(1));
        insert new Task(
            Subject = STATUS_DATA_COLLECTION,
            WhatId = projA.Id,
            Status = 'Not Started',
            ActivityDate = today.addDays(2)
        );

        // Project B: in Data Collection for later transition to Upload Cap Table
        Project__c projB = new Project__c(
            Name = 'Proj B',
            Account__c = acc.Id,
            Project_Status__c = STATUS_DATA_COLLECTION,
            Implementation_Manager__c = runningUserId,
            Target_Go_Live_Date__c = future21,
            Target_Data_Received_Date__c = future14,
            Target_Cap_Table_Uploaded_Date__c = future7
        );
        insert projB;

        // Seed tasks for B: Data Collection and Upload Cap Table
        insert new Task(
            Subject = STATUS_DATA_COLLECTION,
            WhatId = projB.Id,
            Status = 'Not Started',
            ActivityDate = today.addDays(3)
        );
        // insert new Task(Subject = STATUS_UPLOAD_CAP, WhatId = projB.Id, Status = 'Not Started', ActivityDate = today.addDays(4));
        Profile p = [SELECT Id, Name FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User u = new User(
            Alias = 'admin',
            Email = 'admin@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'admin+' + System.currentTimeMillis() + '@cribl.example.com',
            ProfileId = p.Id
        );
        insert u;
    }

    @IsTest
    static void testAfterInsertCreatesKickOffCallTaskSingleAndBulk() {
        // Create two new projects to validate bulk insert handling and task creation
        Id im = UserInfo.getUserId();
        Date today = Date.today();

        // Ensure Account master-detail relationship is satisfied for new Projects
        Account acc = new Account(Name = 'Insert Test Account');
        insert acc;

        Project__c p1 = new Project__c(
            Name = 'New Project 1',
            Account__c = acc.Id,
            Project_Status__c = STATUS_KICK_OFF,
            Implementation_Manager__c = im,
            Target_Go_Live_Date__c = today.addDays(30),
            Target_Data_Received_Date__c = today.addDays(20),
            Target_Cap_Table_Uploaded_Date__c = today.addDays(10)
        );
        Project__c p2 = new Project__c(
            Name = 'New Project 2',
            Account__c = acc.Id,
            Project_Status__c = STATUS_KICK_OFF,
            Implementation_Manager__c = im,
            Target_Go_Live_Date__c = today.addDays(40),
            Target_Data_Received_Date__c = today.addDays(25),
            Target_Cap_Table_Uploaded_Date__c = today.addDays(15)
        );
        User admin = [SELECT Id FROM User WHERE Profile.Name = 'System Administrator' LIMIT 1];
        Test.startTest();
        System.runAs(admin) {
            insert new List<Project__c>{ p1, p2 };
        }
        Test.stopTest();

        // Assert one Kick Off Call task per new project
        Map<Id, Integer> projectIdToKickoffCount = new Map<Id, Integer>();
        for (Task t : [
            SELECT Id, Subject, WhatId, Status, ActivityDate
            FROM Task
            WHERE WhatId IN :new List<Id>{ p1.Id, p2.Id }
        ]) {
            if (STATUS_KICK_OFF == t.Subject) {
                Integer c = projectIdToKickoffCount.get(t.WhatId);
                projectIdToKickoffCount.put(t.WhatId, (c == null ? 1 : c + 1));
                System.assertEquals(
                    'Not Started',
                    t.Status,
                    'After insert: Kick Off Call task should be Not Started for the new project'
                );
                System.assertEquals(
                    Date.today().addDays(7),
                    t.ActivityDate,
                    'After insert: Kick Off Call task ActivityDate should be today + 7'
                );
            }
        }
        System.assertEquals(
            1,
            projectIdToKickoffCount.get(p1.Id),
            'After insert: Exactly one Kick Off Call task should be created for Project 1'
        );
        System.assertEquals(
            1,
            projectIdToKickoffCount.get(p2.Id),
            'After insert: Exactly one Kick Off Call task should be created for Project 2'
        );
    }

    @IsTest
    static void testBeforeUpdateKickOffToDataCollectionHappyPath() {
        // Load seeded Project A and its tasks
        Project__c projA = [
            SELECT
                Id,
                Project_Status__c,
                Implementation_Manager__c,
                Kick_Off_Call_Date__c,
                Data_Received_Date__c,
                Cap_Table_Uploaded_Date__c,
                Go_Live_Date__c,
                Target_Go_Live_Date__c,
                Target_Data_Received_Date__c,
                Target_Cap_Table_Uploaded_Date__c
            FROM Project__c
            WHERE Name = 'Proj A'
            LIMIT 1
        ];

        // Move from Kick Off Call -> Data Collection
        projA.Project_Status__c = STATUS_DATA_COLLECTION;

        User admin = [SELECT Id FROM User WHERE Profile.Name = 'System Administrator' LIMIT 1];
        Test.startTest();
        System.runAs(admin) {
            update projA;
        }
        Test.stopTest();

        // Re-query tasks and project to verify updates
        Project__c refreshed = [
            SELECT
                Id,
                Kick_Off_Call_Date__c,
                Data_Received_Date__c,
                Cap_Table_Uploaded_Date__c,
                Go_Live_Date__c,
                Project_Status__c,
                Implementation_Manager__c,
                Target_Go_Live_Date__c,
                Target_Data_Received_Date__c,
                Target_Cap_Table_Uploaded_Date__c
            FROM Project__c
            WHERE Id = :projA.Id
        ];

        // Kick_Off_Call_Date__c should be set to today when leaving Kick Off
        System.assertEquals(
            Date.today(),
            refreshed.Kick_Off_Call_Date__c,
            'Before update (Kick Off -> Data Collection): Kick_Off_Call_Date__c should be set to today'
        );

        // Tasks: 'Kick Off Call' should be Completed, 'Data Collection' should be In progress and Owner updated
        Task[] related = [
            SELECT Id, Subject, Status, OwnerId, WhatId
            FROM Task
            WHERE WhatId = :projA.Id
        ];
        Boolean kickCompleted = false;
        Boolean dataInProgress = false;
        for (Task t : related) {
            if (STATUS_KICK_OFF == t.Subject) {
                System.assertEquals(
                    'Completed',
                    t.Status,
                    'Before update (Kick Off -> Data Collection): Kick Off Call task should be marked Completed'
                );
                kickCompleted = 'Completed'.equals(t.Status);
            } else if (STATUS_DATA_COLLECTION == t.Subject) {
                System.assertEquals(
                    'In Progress',
                    t.Status,
                    'Before update (Kick Off -> Data Collection): Data Collection task should be marked In Progress'
                );
                System.assertEquals(
                    refreshed.Implementation_Manager__c,
                    t.OwnerId,
                    'Before update (Kick Off -> Data Collection): Data Collection task owner should match Implementation Manager'
                );
                dataInProgress = 'In Progress'.equals(t.Status);
            }
        }
        System.assertEquals(
            true,
            kickCompleted,
            'Before update (Kick Off -> Data Collection): There should be a Kick Off Call task set to Completed'
        );
        System.assertEquals(
            true,
            dataInProgress,
            'Before update (Kick Off -> Data Collection): There should be a Data Collection task set to In Progress'
        );

        // A new "next stage" task should be created for Upload Cap Table when leaving Kick Off Call
        Integer uploadCapCount = [SELECT COUNT() FROM Task WHERE WhatId = :projA.Id AND Subject = :STATUS_UPLOAD_CAP];
        System.assertEquals(
            1,
            uploadCapCount,
            'Before update (Kick Off -> Data Collection): Exactly one Upload Cap Table next-stage task should be created'
        );
    }

    @IsTest
    static void testBeforeUpdateDataCollectionToUploadCapTableHappyPath() {
        // Load seeded Project B
        Project__c projB = [
            SELECT Id, Project_Status__c, Data_Received_Date__c, Implementation_Manager__c
            FROM Project__c
            WHERE Name = 'Proj B'
            LIMIT 1
        ];

        projB.Project_Status__c = STATUS_UPLOAD_CAP;

        User admin = [SELECT Id FROM User WHERE Profile.Name = 'System Administrator' LIMIT 1];
        Test.startTest();
        System.runAs(admin) {
            update projB;
        }
        Test.stopTest();

        // Verify date stamping for Data_Received_Date__c (leaving Data Collection)
        Project__c refreshed = [SELECT Id, Data_Received_Date__c, Project_Status__c FROM Project__c WHERE Id = :projB.Id];
        System.assertEquals(
            Date.today(),
            refreshed.Data_Received_Date__c,
            'Before update (Data Collection -> Upload Cap Table): Data_Received_Date__c should be set to today'
        );

        // Verify tasks updated statuses
        Task[] tasks = [SELECT Id, Subject, Status, OwnerId FROM Task WHERE WhatId = :projB.Id];
        Boolean dataCompleted = false;
        Boolean uploadInProgress = false;
        for (Task t : tasks) {
            if (STATUS_DATA_COLLECTION == t.Subject) {
                System.assertEquals(
                    'Completed',
                    t.Status,
                    'Before update (Data Collection -> Upload Cap Table): Data Collection task should be Completed'
                );
                dataCompleted = true;
            } else if (STATUS_UPLOAD_CAP == t.Subject) {
                System.assertEquals(
                    'In Progress',
                    t.Status,
                    'Before update (Data Collection -> Upload Cap Table): Upload Cap Table task should be In Progress'
                );
                uploadInProgress = true;
            }
        }
        System.assertEquals(
            true,
            dataCompleted,
            'Before update (Data Collection -> Upload Cap Table): There should be a Data Collection task marked Completed'
        );
        System.assertEquals(
            true,
            uploadInProgress,
            'Before update (Data Collection -> Upload Cap Table): There should be an Upload Cap Table task marked In Progress'
        );

        // Code only adds a "next stage" task when leaving Kick Off Call; ensure no extra task was created here
        Integer createdNextTasks = [SELECT COUNT() FROM Task WHERE WhatId = :projB.Id AND Subject = :STATUS_ACTIVATION];
        System.assertEquals(
            0,
            createdNextTasks,
            'Before update (Data Collection -> Upload Cap Table): No new Activation task should be auto-created by current logic'
        );
    }

    @IsTest
    static void testBeforeUpdateInvalidJumpAddError() {
        // Use a fresh project in Kick Off with valid targets, then attempt to jump to Upload Cap Table
        Id im = UserInfo.getUserId();
        Date today = Date.today();

        // Ensure Account master-detail relationship for this scenario
        Account acc = new Account(Name = 'Invalid Jump Test Account');
        insert acc;

        Project__c proj = new Project__c(
            Name = 'Invalid Jump Project',
            Account__c = acc.Id,
            Project_Status__c = STATUS_KICK_OFF,
            Implementation_Manager__c = im,
            Target_Go_Live_Date__c = today.addDays(30),
            Target_Data_Received_Date__c = today.addDays(20),
            Target_Cap_Table_Uploaded_Date__c = today.addDays(10)
        );
        insert proj;

        // Seed tasks needed for handler logic
        insert new Task(Subject = STATUS_KICK_OFF, WhatId = proj.Id, Status = 'Not Started', ActivityDate = today.addDays(1));
        insert new Task(Subject = STATUS_UPLOAD_CAP, WhatId = proj.Id, Status = 'Not Started', ActivityDate = today.addDays(2));

        // Attempt invalid transition: Kick Off -> Upload Cap Table (skips Data Collection)
        proj.Project_Status__c = STATUS_UPLOAD_CAP;

        try {
            User admin = [SELECT Id FROM User WHERE Profile.Name = 'System Administrator' LIMIT 1];
            Test.startTest();
            System.runAs(admin) {
                update proj;
            }
            Test.stopTest();
            Assert.fail('Invalid jump: Update should have thrown a DmlException due to addError on Project_Status__c');
        } catch (DmlException ex) {
            Assert.isTrue(
                ex.getMessage().contains('Status can only be changed to the next stage'),
                'Invalid jump: Error message should indicate only next-stage transitions are allowed'
            );
        }

        // Ensure no unintended task updates occurred (Kick Off should remain Not Started)
        Task kick = [SELECT Id, Status FROM Task WHERE WhatId = :proj.Id AND Subject = :STATUS_KICK_OFF LIMIT 1];
        System.assertEquals(
            'Not Started',
            kick.Status,
            'Invalid jump: Kick Off Call task should not be auto-completed on failed update'
        );
    }

    @IsTest
    @SuppressWarnings(
        'PMD.ApexUnitTestClassShouldHaveAsserts'
    ) // This test delegates assertions to the assertUpdateFailsWithMessage helper
    static void testBeforeUpdateMissingOrPastTargetDatesAddError() {
        Id im = UserInfo.getUserId();
        Date today = Date.today();
        User admin = [SELECT Id FROM User WHERE Profile.Name = 'System Administrator' LIMIT 1];
        Test.startTest();
        System.runAs(admin) {
            // Ensure Account master-detail relationship for validation scenarios
            Account acc = new Account(Name = 'Validation Test Account');
            insert acc;

            // Helper to insert a base project at Kick Off
            Project__c base = new Project__c(
                Name = 'Validation Project',
                Account__c = acc.Id,
                Project_Status__c = STATUS_KICK_OFF,
                Implementation_Manager__c = im,
                Target_Go_Live_Date__c = today.addDays(30),
                Target_Data_Received_Date__c = today.addDays(20),
                Target_Cap_Table_Uploaded_Date__c = today.addDays(10)
            );
            insert base;
            insert new Task(Subject = STATUS_KICK_OFF, WhatId = base.Id, Status = 'Not Started', ActivityDate = today.addDays(1));
            insert new Task(
                Subject = STATUS_DATA_COLLECTION,
                WhatId = base.Id,
                Status = 'Not Started',
                ActivityDate = today.addDays(2)
            );

            // Case 1: Null Target_Go_Live_Date__c
            Project__c p1 = base.clone(false, false, false, false);
            p1.Name = 'Validation Project - Null Go Live';
            p1.Account__c = acc.Id;
            insert p1;
            insert new Task(Subject = STATUS_KICK_OFF, WhatId = p1.Id, Status = 'Not Started', ActivityDate = today.addDays(1));
            insert new Task(
                Subject = STATUS_DATA_COLLECTION,
                WhatId = p1.Id,
                Status = 'Not Started',
                ActivityDate = today.addDays(2)
            );
            p1.Target_Go_Live_Date__c = null;
            p1.Project_Status__c = STATUS_DATA_COLLECTION;
            assertUpdateFailsWithMessage(p1, 'Target Go Live Date must be completed and in the future');

            // Case 2: Past Target_Data_Received_Date__c
            Project__c p2 = base.clone(false, false, false, false);
            p2.Name = 'Validation Project - Past Data Received';
            p2.Account__c = acc.Id;
            insert p2;
            insert new Task(Subject = STATUS_KICK_OFF, WhatId = p2.Id, Status = 'Not Started', ActivityDate = today.addDays(1));
            insert new Task(
                Subject = STATUS_DATA_COLLECTION,
                WhatId = p2.Id,
                Status = 'Not Started',
                ActivityDate = today.addDays(2)
            );
            p2.Target_Data_Received_Date__c = today.addDays(-1);
            p2.Project_Status__c = STATUS_DATA_COLLECTION;
            assertUpdateFailsWithMessage(p2, 'Target Data Received Date must be completed and in the future');

            // Case 3: Past Target_Cap_Table_Uploaded_Date__c
            Project__c p3 = base.clone(false, false, false, false);
            p3.Name = 'Validation Project - Past Cap Table';
            p3.Account__c = acc.Id;
            insert p3;
            insert new Task(Subject = STATUS_KICK_OFF, WhatId = p3.Id, Status = 'Not Started', ActivityDate = today.addDays(1));
            insert new Task(
                Subject = STATUS_DATA_COLLECTION,
                WhatId = p3.Id,
                Status = 'Not Started',
                ActivityDate = today.addDays(2)
            );
            p3.Target_Cap_Table_Uploaded_Date__c = today.addDays(-1);
            p3.Project_Status__c = STATUS_DATA_COLLECTION;
            assertUpdateFailsWithMessage(p3, 'Target Cap Table Uploaded Date must be completed and in the future');
        }
        Test.stopTest();
    }

    // Helper that asserts an update fails with a message containing the expected snippet
    private static void assertUpdateFailsWithMessage(Project__c recordToUpdate, String expectedMessageSnippet) {
        try {
            update recordToUpdate;
            Assert.fail('Validation error: Update should throw DmlException due to addError on one of the target date fields');
        } catch (DmlException ex) {
            Assert.isTrue(
                ex.getMessage().contains(expectedMessageSnippet),
                'Validation error: DML exception message should contain the expected validation snippet: ' +
                expectedMessageSnippet
            );
        }
    }
}
