trigger ProjectTrigger on Project__c(after insert, before update) {
    ProjectTriggerHandler.executeTrigger((List<Project__c>) Trigger.new, (Map<Id, Project__c>) Trigger.oldMap);
}
