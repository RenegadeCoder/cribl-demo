/**
 * @description Unit tests for ContactTriggerHandler covering positive and negative paths.
 */
@IsTest
private class ContactTriggerHandlerTests {
    /**
     * Common test data for all tests.
     * - Two Accounts (A1, A2)
     * - Two Contacts linked to those Accounts
     */
    @TestSetup
    static void setupData() {
        List<Account> accts = new List<Account>{ new Account(Name = 'Acme A1'), new Account(Name = 'Beta A2') };
        insert accts;

        List<Contact> cons = new List<Contact>{
            new Contact(FirstName = 'Orig', LastName = 'One', AccountId = accts[0].Id),
            new Contact(FirstName = 'Orig', LastName = 'Two', AccountId = accts[1].Id)
        };
        insert cons;

        // Arrange: create an admin user
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

    /**
     * Positive path:
     * - Update Contact.FirstName to 'Test' and change value, triggering handler
     * - Expect exactly one Account (the linked one) to have Name set to Contact Id string
     */
    @IsTest
    static void afterUpdatePositiveSingleContact() {
        User admin = [SELECT Id FROM User WHERE Profile.Name = 'System Administrator' LIMIT 1];
        // Arrange
        Account a1 = [SELECT Id, Name FROM Account WHERE Name = 'Acme A1' LIMIT 1];
        Contact c1 = [SELECT Id, FirstName, LastName, AccountId FROM Contact WHERE AccountId = :a1.Id LIMIT 1];

        // Pre-assertions
        System.assertNotEquals('Test', c1.FirstName, 'Precondition: Contact FirstName must not already be "Test"');

        // Act
        Test.startTest();
        System.runAs(admin) {
            c1.FirstName = 'Test';
            update c1; // Triggers after update path
        }
        Test.stopTest();

        // Assert
        Account a1After = [SELECT Id, Name FROM Account WHERE Id = :a1.Id LIMIT 1];
        System.assertEquals(
            (String) c1.Id,
            a1After.Name,
            'Account name should be updated to the qualifying Contact Id when FirstName changes to "Test"'
        );

        // Ensure other account unaffected
        Account a2After = [SELECT Id, Name FROM Account WHERE Name = 'Beta A2' LIMIT 1];
        System.assertEquals(
            'Beta A2',
            a2After.Name,
            'Non-qualifying Accounts must remain unchanged when only one Contact qualifies'
        );
    }

    /**
     * Positive path with multiple qualifying Contacts under same Account:
     * - Ensure exactly one update per account occurs (loop uses keySet and i < 1)
     * - The account Name should match the Id of the first qualifying contact in the list for that Account
     */
    @IsTest
    static void afterUpdatePositiveMultipleContactsSameAccountSingleUpdate() {
        // Arrange
        Account a1 = [SELECT Id, Name FROM Account WHERE Name = 'Acme A1' LIMIT 1];
        List<Contact> a1Contacts = [
            SELECT Id, FirstName, LastName, AccountId
            FROM Contact
            WHERE AccountId = :a1.Id
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];

        // Create an additional Contact under same Account to qualify
        Contact extra = new Contact(FirstName = 'Orig', LastName = 'Three', AccountId = a1.Id);
        insert extra;

        // Prepare both to qualify by changing FirstName to 'Test'
        a1Contacts[0].FirstName = 'Test';
        extra.FirstName = 'Test';

        User admin = [SELECT Id FROM User WHERE Profile.Name = 'System Administrator' LIMIT 1];
        // Act
        Test.startTest();
        System.runAs(admin) {
            update new List<Contact>{ a1Contacts[0], extra };
        }
        Test.stopTest();

        // Assert: Only one contact per account is used to set the Name.
        // We cannot guarantee which of the two was taken without inspecting order; the code adds in qualify order,
        // then updateAccountNames picks the 0-th element for that account. Since we updated a list with [cFirst, extra],
        // the first element is expected to be used.
        Account a1After = [SELECT Id, Name FROM Account WHERE Id = :a1.Id LIMIT 1];

        // Determine expected based on update order (first element)
        String expectedName = (String) a1Contacts[0].Id;
        System.assertEquals(
            expectedName,
            a1After.Name,
            'When multiple Contacts under the same Account qualify, only one update should occur using the first qualifying Contact'
        );
    }

    /**
     * Negative path: FirstName changed but not to 'Test' => should NOT qualify
     * - Ensure Account Name remains unchanged
     */
    @IsTest
    static void afterUpdateNegativeChangedButNotTest() {
        // Arrange
        Account a2 = [SELECT Id, Name FROM Account WHERE Name = 'Beta A2' LIMIT 1];
        Contact c2 = [SELECT Id, FirstName, LastName, AccountId FROM Contact WHERE AccountId = :a2.Id LIMIT 1];

        User admin = [SELECT Id FROM User WHERE Profile.Name = 'System Administrator' LIMIT 1];
        // Act
        Test.startTest();
        System.runAs(admin) {
            c2.FirstName = 'SomethingElse';
            update c2; // Does not meet 'Test' criteria
        }
        Test.stopTest();

        // Assert
        Account a2After = [SELECT Id, Name FROM Account WHERE Id = :a2.Id LIMIT 1];
        System.assertEquals(
            'Beta A2',
            a2After.Name,
            'Account name should not change when Contact.FirstName changes but is not "Test"'
        );
    }

    /**
     * Negative path: FirstName is already 'Test' but does NOT change => should NOT qualify
     * - Ensure Account Name remains unchanged
     */
    @IsTest
    static void afterUpdateNegativeNoChangeEvenIfTest() {
        // Arrange
        Account a1 = [SELECT Id, Name FROM Account WHERE Name = 'Acme A1' LIMIT 1];
        // Create a fresh contact with FirstName already 'Test'
        Contact c = new Contact(FirstName = 'Test', LastName = 'Four', AccountId = a1.Id);
        insert c;

        User admin = [SELECT Id FROM User WHERE Profile.Name = 'System Administrator' LIMIT 1];
        // Act: Update a non-FirstName field so that FirstName does not change
        Test.startTest();
        System.runAs(admin) {
            c.LastName = 'FourUpdated';
            update c; // Does not meet "changed and equals 'Test'" condition
        }
        Test.stopTest();

        // Assert
        Account a1After = [SELECT Id, Name FROM Account WHERE Id = :a1.Id LIMIT 1];
        System.assertEquals(
            'Acme A1',
            a1After.Name,
            'Account name should remain unchanged when Contact.FirstName remains "Test" but does not change in the update'
        );
    }

    /**
     * Error-path validation using non-admin runAs:
     * - Create a standard user (non-System Administrator) and perform the qualifying Contact update under runAs.
     * - Since the handler performs Database.update in SYSTEM_MODE, the inner Account update executes successfully,
     *   but the outer DML (Contact update) should execute in user context. To satisfy the requirement, we wrap in try/catch
     *   and assert no unexpected exceptions occur, documenting behavior.
     * Note: In many orgs, non-admin users may not have edit permission on Account or Contact. If such permission
     * is restricted in the target org, this test will capture the exception and assert its presence as the negative path.
     */
    @IsTest
    static void errorPathRunAsNonAdminWithTryCatch() {
        // Arrange: create a non-admin user
        Profile p = [SELECT Id, Name FROM Profile WHERE Name != 'System Administrator' LIMIT 1];
        User u = new User(
            Alias = 'stdusr',
            Email = 'stdusr@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'stdusr+' + System.currentTimeMillis() + '@cribl.example.com',
            ProfileId = p.Id
        );
        insert u;

        Account a = [SELECT Id, Name FROM Account WHERE Name = 'Acme A1' LIMIT 1];
        Contact c = [SELECT Id, FirstName, LastName, AccountId FROM Contact WHERE AccountId = :a.Id LIMIT 1];
        Test.startTest();
        System.runAs(u) {
            try {
                // Act: qualifying change under non-admin context
                c.FirstName = 'Test';
                update c;
                Assert.fail('Expected an VR exception to be thrown under non-admin runAs, but no exception was thrown');
            } catch (Exception e) {
                Assert.isTrue(
                    e.getMessage().contains('You cannot change this information on an account.'),
                    'Expected authorization exception not thrown. Instead found: ' + e.getMessage()
                );
            }
        }
        Test.stopTest();
    }
}
