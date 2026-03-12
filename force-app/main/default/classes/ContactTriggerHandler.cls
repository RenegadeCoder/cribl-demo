/**
 * Handles contact trigger logic including updating account names based on contact first name changes.
 * Without sharing is used to allow the trigger handler to update contacts without running into sharing issues
 */
public without sharing class ContactTriggerHandler {
    /**
     * This method is called from the trigger to handle the context swapping logic
     */
    public static void executeTrigger() {
        if (Trigger.isAfter && Trigger.isUpdate) {
            afterUpdate((List<Contact>) Trigger.new, (Map<Id, Contact>) Trigger.oldMap);
        }
        // else if (Trigger.isAfter && Trigger.isInsert) {
        //     afterInsert((List<Contact>) Trigger.new);
        // }
    }

    // placeholder for after insert logic, not needed for current use case
    /*
    private static void afterInsert(List<Contact> newContacts) {
        Map<Id, Contact[]> accountIdToContactsMap = qualifyForAccountUpdate(newContacts, new Map<Id, Contact>());
        if (!accountIdToContactsMap.isEmpty()) {
            updateAccountNames(accountIdToContactsMap);
        }
    }
    */
    private static void afterUpdate(List<Contact> newContacts, Map<Id, Contact> oldContactMap) {
        Map<Id, Contact[]> accountIdToContactsMap = qualifyAccountUpdates(newContacts, oldContactMap);
        if (!accountIdToContactsMap.isEmpty()) {
            updateAccountNames(accountIdToContactsMap);
        }
    }

    private static Map<Id, Contact[]> qualifyAccountUpdates(List<Contact> newContacts, Map<Id, Contact> oldContactMap) {
        Map<Id, Contact[]> accountIdToContactsMap = new Map<Id, Contact[]>();
        for (Contact con : newContacts) {
            if (con.FirstName != oldContactMap.get(con.Id).FirstName && 'Test'.equals(con.FirstName)) {
                if (!accountIdToContactsMap.containsKey(con.AccountId)) {
                    //populate with empty list for better code coverage
                    accountIdToContactsMap.put(con.AccountId, new List<Contact>{});
                } // the following line will always run even if there's only only one contact in the list --> full code coverage for unit tests
                accountIdToContactsMap.get(con.AccountId).add(con);
            }
        }
        return accountIdToContactsMap;
    }

    private static void updateAccountNames(Map<Id, Contact[]> accountIdToContactsMap) {
        Account[] accountsToUpdate = new List<Account>{};
        for (Id accountId : accountIdToContactsMap.keySet()) {
            for (Integer i = 0; i < 1; i++) {
                //take ONLY ONE contact per account to prevent duplicate updates.
                // List is preserved for future business logic which may come before this line

                accountsToUpdate.add(new Account(Id = accountId, Name = accountIdToContactsMap.get(accountId)[0]?.Id));
                // In a real use case, we would likely want other details about the Contacts rather than jsut the Id,
                // so I didn't want to lock this in as a Map<Id,Id> for the sake of future flexibility.
                // This is just a placeholder to show how we can use the list of contacts in the trigger handler to update the account.
            }
        }
        List<Database.SaveResult> saveResults = Database.update(
            accountsToUpdate,
            false,
            System.AccessLevel.SYSTEM_MODE
        );
        // real implementation would log the failed save results for later reporting
        for (Database.SaveResult result : saveResults) {
            if (!result.isSuccess()) {
                Id failedAccount = result.getId();
                for (Contact con : accountIdToContactsMap.get(failedAccount)) {
                    for (Database.Error error : result.getErrors()) {
                        con.addError(error.getMessage());
                    }
                }
            }
        }
    }
}
