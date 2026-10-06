# Bank reconciliation

Import XLSX, XLS and CSV statements after reviewing column mappings and duplicates. Originals are stored privately for audit.

The bank statement and registered Sales Invoices / GST expenses appear side by side with search, date and credit/debit filters. Invoice columns combine supplier/GSTIN/buyer, invoice number and total. Selections retain totals across filters. Matching requires equal credit and debit sums separately in one currency. Matched rows turn green, cannot be reused, and saved groups appear below.

Matching stores immutable snapshots and links only; it does not create payment allocations or mark invoices paid. Full invoice matching is supported; partial invoice allocation is not part of this screen. Existing payments and invoices are preserved.

Database reads require India project membership. Writes run through an atomic RPC with membership checks, row locks, duplicate prevention and authoritative totals. Original statement files cannot be overwritten or deleted from the client.

Expenses have row checkboxes, visible select/clear, selected totals by currency, and Excel exports for selected or filtered rows.
