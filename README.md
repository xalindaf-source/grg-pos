# Garden Route Green POS

The shop uses one shared Supabase database. Everyone signs in with their own email and password. All staff can sell, manage day-to-day stock, prepare purchase orders, create invoices, update payment status and view reports. Sales and new invoices record the signed-in account.

The owner can also manage team access, edit shop settings and category lists, back up or restore shop records, delete products or invoices, and void sales. The database checks these permissions independently of the controls shown in the app.

## Set up the shared shop

1. Open the current live app on the browser that holds your most complete records. Go to **Settings → Back up data**. The previous app saved locally per browser. If several devices have different records, export each and reconcile the backups before restoring. Keep the original exports.
2. Use a Supabase project for this shop. Run [setup.sql](setup.sql) in its SQL Editor. In Authentication settings, turn off public sign-ups and anonymous sign-ins.
3. In **Authentication → Users**, create or invite the owner's email and the four employee emails. Each account needs a confirmed email and its own password. Set or reset passwords through Supabase Auth. In SQL Editor, run the following with your confirmed owner email and display name. The query should return one row. Verify that it is your account before sharing the app.
   
   ```sql
   insert into public.grg_members (user_id, display_name, role)
   select id, 'Xalinda', 'owner'
   from auth.users
   where lower(email) = lower('replace-with-owner-email') and email_confirmed_at is not null
   returning user_id, display_name, role;
   ```
4. Set the project URL and public publishable key in [shop-config.js](shop-config.js). The deployed app exposes this file to browsers. Use only the publishable key. Serve the files together over HTTPS.
5. Sign in as the owner. Open **Settings → Restore** and import the reconciled backup. Confirm stock, sales, invoices and settings. Restore replaces the shared records and preserves historical salesperson names.
6. Go to **Settings → Manage team**, enter each confirmed employee email and display name, and select **Approve access**. All four accounts receive the same staff permissions. **Remove access** blocks shop requests for that account.
7. Before switching the live shop over, test two devices with separate logins. Check that a sale updates stock on both devices, that invoices get the next number, and that a staff account cannot open owner settings or perform a deletion. Keep the old app and final backup until you have checked the migrated records.

The shared version requires an internet connection. If two devices save against the same revision, the first write succeeds and the second device refreshes so its operator can review and retry. A checkout writes the sale, stock and optional invoice in one database transaction. If the connection interrupts a save, **Retry save** checks or repeats the same operation without duplicating it.
