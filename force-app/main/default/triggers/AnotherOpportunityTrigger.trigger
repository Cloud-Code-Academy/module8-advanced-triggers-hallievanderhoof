/*
AnotherOpportunityTrigger Overview

This trigger was initially created for handling various events on the Opportunity object. It was developed by a prior developer and has since been noted to cause some issues in our org.

IMPORTANT:
- This trigger does not adhere to Salesforce best practices.
- It is essential to review, understand, and refactor this trigger to ensure maintainability, performance, and prevent any inadvertent issues.

ISSUES:
Avoid nested for loop - 1 instance
Avoid DML inside for loop - 1 instance
Bulkify Your Code - 1 instance
Avoid SOQL Query inside for loop - 2 instances
Stop recursion - 1 instance

RESOURCES: 
https://www.salesforceben.com/12-salesforce-apex-best-practices/
https://developer.salesforce.com/blogs/developer-relations/2015/01/apex-best-practices-15-apex-commandments
*/

trigger AnotherOpportunityTrigger on Opportunity (before insert, before update, before delete, after insert, after delete, after undelete) {
    
    // --- BEFORE CONTEXT ---
    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            // REF: Bulkify Your Code (Iterate all records, not just new[0])
            for (Opportunity opp : Trigger.new) {
                if (opp.Type == null) {
                    opp.Type = 'New Customer';
                }
            }
        } 
        else if (Trigger.isUpdate) {
            // REF: Stop Recursion & Avoid Nested For Loop
            // Moved logic from 'after update' to 'before update'. 
            // This removes the need for 'update Trigger.new' (DML) which caused recursion.
            for (Opportunity opp : Trigger.new) {
                // Use oldMap to avoid nested loop over Trigger.old
                Opportunity oldOpp = Trigger.oldMap.get(opp.Id);
                
                // Check if Stage has changed
                if (opp.StageName != oldOpp.StageName && opp.StageName != null) {
                    String currentDesc = (opp.Description != null) ? opp.Description : '';
                    opp.Description = currentDesc + '\n Stage Change:' + opp.StageName + ':' + DateTime.now().format();
                }
            }
        }
        else if (Trigger.isDelete) {
            // Prevent deletion of closed Opportunities
            for (Opportunity opp : Trigger.old) {
                if (opp.IsClosed) {
                    opp.addError('Cannot delete closed opportunity');
                }
            }
        }
    }

    // --- AFTER CONTEXT ---
    if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            // REF: Avoid DML inside for loop
            List<Task> tasksToInsert = new List<Task>();
            
            for (Opportunity opp : Trigger.new) {
                Task tsk = new Task();
                tsk.Subject = 'Call Primary Contact';
                tsk.WhatId = opp.Id;
                tsk.WhoId = opp.Primary_Contact__c;
                tsk.OwnerId = opp.OwnerId;
                tsk.ActivityDate = Date.today().addDays(3);
                tasksToInsert.add(tsk);
            }
            
            if (!tasksToInsert.isEmpty()) {
                insert tasksToInsert;
            }
        } 
        else if (Trigger.isDelete) {
            notifyOwnersOpportunityDeleted(Trigger.old);
        } 
        else if (Trigger.isUndelete) {
            assignPrimaryContact(Trigger.new);
        }
    }

    /*
    * Helper Methods
    */

    private static void notifyOwnersOpportunityDeleted(List<Opportunity> opps) {
        // REF: Avoid SOQL Query inside for loop
        Set<Id> ownerIds = new Set<Id>();
        for (Opportunity opp : opps) {
            ownerIds.add(opp.OwnerId);
        }

        // Query all users at once and map them
        Map<Id, User> userMap = new Map<Id, User>([SELECT Id, Email FROM User WHERE Id IN :ownerIds]);

        List<Messaging.SingleEmailMessage> mails = new List<Messaging.SingleEmailMessage>();
        
        for (Opportunity opp : opps) {
            if (userMap.containsKey(opp.OwnerId)) {
                User u = userMap.get(opp.OwnerId);
                if (u.Email != null) {
                    Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
                    mail.setToAddresses(new String[] { u.Email });
                    mail.setSubject('Opportunity Deleted : ' + opp.Name);
                    mail.setPlainTextBody('Your Opportunity: ' + opp.Name +' has been deleted.');
                    mails.add(mail);
                }
            }
        }        
        
        if (!mails.isEmpty()) {
            try {
                Messaging.sendEmail(mails);
            } catch (Exception e) {
                System.debug('Exception: ' + e.getMessage());
            }
        }
    }

    private static void assignPrimaryContact(List<Opportunity> opps) {        
        // REF: Avoid SOQL Query inside for loop
        List<Opportunity> oppsToUpdate = new List<Opportunity>();
        Set<Id> accountIds = new Set<Id>();

        // 1. Collect Account IDs from Opportunities needing a contact
        for (Opportunity opp : opps) {
            if (opp.Primary_Contact__c == null && opp.AccountId != null) {
                accountIds.add(opp.AccountId);
            }
        }

        // 2. Bulk Query Contacts for these Accounts
        // Mapping AccountId -> ContactId
        Map<Id, Id> accountToContactMap = new Map<Id, Id>();
        List<Contact> contacts = [SELECT Id, AccountId FROM Contact WHERE Title = 'VP Sales' AND AccountId IN :accountIds];
        
        for (Contact c : contacts) {
            // Note: If multiple VP Sales exist, this logic picks the last one in the list.
            // This mimics the original behavior of "LIMIT 1" somewhat loosely but bulkified.
            accountToContactMap.put(c.AccountId, c.Id);
        }

        // 3. Assign Contacts
        for (Opportunity opp : opps) {
            if (opp.Primary_Contact__c == null && accountToContactMap.containsKey(opp.AccountId)) {
                Opportunity oppToUpdate = new Opportunity(Id = opp.Id);
                oppToUpdate.Primary_Contact__c = accountToContactMap.get(opp.AccountId);
                oppsToUpdate.add(oppToUpdate);
            }
        }
        
        if (!oppsToUpdate.isEmpty()) {
            update oppsToUpdate;
        }
    }
}