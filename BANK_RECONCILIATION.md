# Bank reconciliation

Import XLSX, XLS and CSV statements after reviewing column mappings and duplicates. Originals are stored privately for audit.

The bank statement and registered Sales Invoices / GST expenses appear side by side with search, date and credit/debit filters. Invoice columns combine supplier/GSTIN/buyer, invoice number and total. Selections retain totals across filters. Matching compares net amounts in one currency. Unequal amounts require a described adjustment for the exact difference; the adjustment and match save atomically. Matched rows turn green, cannot be reused, and saved groups appear below.

Matching stores immutable snapshots and links only; it does not create payment allocations or mark invoices paid. Full invoice matching is supported; partial invoice allocation is not part of this screen. Existing payments and invoices are preserved.

Database reads require India project membership. Writes run through an atomic RPC with membership checks, row locks, duplicate prevention and authoritative totals. Original statement files cannot be overwritten or deleted from the client.

Expenses have row checkboxes, visible select/clear, selected totals by currency, and Excel exports for selected or filtered rows.

Register Order Payment entries are shared in Supabase; USD payments use their saved converted INR amount. Legacy locally saved order payments sync when the Financial or Reconciliation tab opens, provided their registered bank can be resolved uniquely. Manual financial expenses are shared debit entries. Adjustments belong to their match and cannot be selected again.

The complete PDF groups all reconciliations for the selected bank and currency by statement month, using the earliest bank transaction date in each matched group. Bank and system snapshots appear side by side, including adjustment descriptions and final zero differences. Use Print / Save as PDF.

Apply bank_reconciliation_adjustments.sql after the base bank_reconciliation.sql migration. No example records are included.
