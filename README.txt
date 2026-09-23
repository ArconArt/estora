ESTORA
Joinery, fit-out and door estimating. Version 1.0 (cloud edition)
================================================================

FILES
  OWNER-SETUP.md ............... START HERE. The ten-minute launch list:
                                  database, GitHub + Cloudflare Pages,
                                  Supabase settings, your owner account.
  web/ .......................... The installable version. Upload the
                                  CONTENTS of this folder to your GitHub
                                  repository; Cloudflare Pages publishes it.
                                  Customers click Install and get a desktop
                                  or phone icon.
  estora.html ................... The same app as one single file, for
                                  emailing or opening straight from a disk.
  estora-supabase-schema.sql .... Database + security rules. Run it once in
                                  the Supabase SQL editor. Safe to run again.
  license-keygen.html ........... YOUR tool. Never send this to a customer.
  estora-logo.svg / icons ....... The ESTORA mark (web/ holds the PNG icons).
  README.txt .................... This file.
  SAUDI-RIYAL-FONT-LICENSE.txt .. Licence of the embedded Saudi Riyal sign
                                  font (SIL OFL 1.1). Keep it with the app.

YOUR SUPABASE PROJECT IS ALREADY FILLED IN
  estora.html and web/index.html point at the same Supabase project as
  Control Room (search for CLOUD_URL). Every ESTORA table and function
  starts with es_, so the two products share the project without touching
  each other. To use a separate project, change CLOUD_URL and CLOUD_KEY in
  both files and run the SQL there instead.

BEFORE YOU SELL TO ANYONE - THREE THINGS
  1. Run estora-supabase-schema.sql (Supabase -> SQL Editor -> paste all -> Run).
  2. Make yourself the owner, in the same SQL editor:
       insert into es_owners (email) values ('you@yourdomain.com');
     using the email you will sign in to ESTORA with.
  3. Change the licence secret, in BOTH places, to the same private string:
       update es_vendor set value = 'YOUR-OWN-SECRET' where key = 'license_secret';
       and LICENSE_SECRET in license-keygen.html.

WHAT A CUSTOMER DOES
  Opens your address -> "New company? Create a workspace" -> company name,
  their name, email, password. They are the administrator, on a 7-day free
  trial: 2 users, 1 project, 5 schedule items. They add their team under
  Team & access; each colleague gets an invitation with a 6-character code
  and chooses their own password.

PLANS (USD per year)
  Free trial   7 days    2 users,  1 project, 5 items
  Starter      $99       2 users,  5 projects
  Team         $199      6 users, 10 projects
  Business     $299     10 users, 15 projects
  Enterprise   $499     unlimited
  The DATABASE enforces these - seats, projects, trial items and expiry -
  so a modified browser cannot get round them. To lift every limit while
  you test:  update es_vendor set value = 'off' where key = 'enforce_limits';

GETTING PAID (manual, for now)
  The customer presses "Choose ..." under Licence & billing and sends you
  the pre-filled message. They pay you by bank transfer or a payment link.
  Then EITHER
    - open ESTORA -> Owner -> Set plan on their row (plan, expiry, amount,
      reference). It applies at once and records the payment; OR
    - open license-keygen.html, generate a key and email it. They paste it
      under Licence & billing -> Activate. The server checks it.
  To send buyers to a hosted checkout instead, put the links in
  CHECKOUT_LINKS near the top of the HTML (both files). A payment
  provider's webhook can later call es_record_payment() with the service
  key to switch plans on automatically.

ROLES
  Administrator  everything, including team, branding and licence
  Manager        creates and removes projects, parameters, margins and the
                 company rate library
  Estimator      prices items and edits rates on the projects they are given
  Viewer         reads and exports only
  Each person can also be limited to chosen projects and chosen tabs.

HOW THE PRICING WORKS
  Every item becomes a real cut list. Sheet goods are nested across the
  whole project; the BOM buys exactly the sheets in the cutting layout and
  each item carries its share. Finishes come from net panel area; edge
  banding from panel edges. Each project keeps its own copy of the rates,
  so a submitted quotation never moves when prices change elsewhere; new
  projects start from the company rate library.

CURRENCY
  48 currencies. SAR shows the new Saudi Riyal sign (U+20C1); a tiny
  open-source font is built into the page so it shows on every device,
  including those whose system fonts do not have the sign yet.

EXPORTS
  Schedule (with the full cost build-up), BOM and cut list, as Excel files
  carrying the customer's own logo.

ARCON(TM) - A Product Brand of ORCHE (PVT) LTD.
(c) 2026 ORCHE (PVT) LTD. All Rights Reserved.
