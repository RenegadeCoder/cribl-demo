trigger ContactsTrigger on Contact(after update) {
    ContactTriggerHandler.executeTrigger();
}
