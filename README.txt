ESTORA
Joinery, fit-out and door estimating. Version 2.0 (single-user edition)
=======================================================================

FILES
  OWNER-SETUP.md ............... START HERE. Database, GitHub + Cloudflare
                                  Pages, Supabase settings, your owner account.
  web/ .......................... The installable version. Upload the
                                  CONTENTS of this folder to your GitHub
                                  repository; Cloudflare Pages publishes it.
                                  Customers click Install and get a desktop
                                  icon; .estora files then open in ESTORA.
  estora.html ................... The same app as one single file.
  estora-supabase-schema.sql .... Accounts, licences and company settings.
                                  Run it once in the Supabase SQL editor.
                                  Safe to run again; upgrades the team edition.
  license-keygen.html ........... YOUR tool. Never send this to a customer.
  estora-logo.svg / icons ....... The ESTORA mark (web/ holds the PNG icons).
  README.txt .................... This file.
  SAUDI-RIYAL-FONT-LICENSE.txt .. Licence of the embedded Saudi Riyal sign
                                  font (SIL OFL 1.1). Keep it with the app.

HOW IT WORKS FOR A CUSTOMER
  One person, one licence. They sign in; their projects are .estora files on
  their own computer:
    New project ... starts from their company rate library
    Save .......... Ctrl+S. Chrome and Edge save straight back into the same
                    file; other browsers download a fresh copy each time
    Save a copy ... under Export
    Open file ..... Ctrl+O, or pick from Recent files on the Projects page
  Unsaved work is kept as a draft in the browser and offered back if the
  window closes before saving.

PLANS (USD, one user)
  Free trial   7 days     up to 5 items per project
  Monthly      9.25       30 days
  Yearly       69.25      365 days
  The DATABASE holds the plan and expiry, so a modified browser cannot extend
  them. To lift every limit while you test:
    update es_vendor set value = 'off' where key = 'enforce_limits';

GETTING PAID (manual, for now)
  The customer presses Choose Monthly / Yearly under Licence and sends you the
  pre-filled message. When they have paid, either
    - ESTORA -> Owner -> Set plan on their row (it records the payment), or
    - license-keygen.html -> generate a key and email it; they paste it
      under Licence -> Activate.

WHAT ESTORA PRICES
  Schedule items: cabinets and wardrobes, kitchen base / wall / tall units,
  vanities, door sets (single or double leaf) and timber profiles (skirting,
  beads, cornices...). Each item card can be minimised to one line, and opens
  its Materials & cost, Cut list and Hardware sections on demand.
  - Drawers: Outside (fronts on the face; the doors are shortened) or Inside
    (behind full-height doors; fronts in carcase board).
  - Doors: Auto / Single / Double leaf. Every leaf takes its own core blank,
    so a double door uses two.
  - Hardware: change a counted quantity, swap the item, remove it or add your
    own, per item. Door ironmongery sets are edited under Ironmongery, and a
    single door can be customised on its card.
  - Profiles & sizes: door frame, architrave, lipping, stile & rail and other
    timber sections with their wastage %, standard sizes per item type, and
    the sawn thickness classes (1", 1½", 2" ...).
  - Wastage: defaults under Parameters (area finishes, door-leaf finishes,
    edge banding); any material can carry its own Waste % under Rates.
  - Cutting & timber: every sheet material nested across the project with its
    cutting layouts and cut list, and solid timber in m³ by species, hardwood /
    softwood and sawn thickness.

EXPORTS
  Estimate, Material BOM, Cutting layouts & timber — as PDF and as Excel,
  each carrying the customer's own logo. PDFs show amounts with the currency
  code (SAR, AED...); the app itself shows the new Saudi Riyal sign.

CURRENCY
  48 currencies. SAR shows the new Saudi Riyal sign (U+20C1); a tiny
  open-source font is built into the page so it shows on every device.

ARCON(TM) - A Product Brand of ORCHE (PVT) LTD.
(c) 2026 ORCHE (PVT) LTD. All Rights Reserved.
