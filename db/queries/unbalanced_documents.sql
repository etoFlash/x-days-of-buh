-- ============================================================================
-- unbalanced_documents.sql — поиск несбалансированных документов
-- ============================================================================
-- Главный сверочный контроль главной книги. Триггер check_entry_balance
-- не даёт зафиксировать несбалансированную проводку, поэтому этот запрос
-- должен ВСЕГДА возвращать 0 строк (и ненулевой контрольный итог ниже — 0).
-- Если строки появились — журнал повреждён в обход триггера: инцидент.
--
-- Запуск из psql:
--   psql ... -f db/queries/unbalanced_documents.sql
-- ============================================================================

\echo ''
\echo '=== Несбалансированные документы (должно быть пусто) ==='

SELECT
    d.document_id,
    d.operating_day,
    d.doc_type,
    d.description,
    SUM(COALESCE(el.debit_amount, 0))  AS sum_debit,
    SUM(COALESCE(el.credit_amount, 0)) AS sum_credit,
    SUM(COALESCE(el.debit_amount, 0))
      - SUM(COALESCE(el.credit_amount, 0)) AS imbalance
FROM documents d
JOIN journal_entries je ON je.document_id = d.document_id
LEFT JOIN entry_lines el ON el.entry_id = je.entry_id
GROUP BY d.document_id, d.operating_day, d.doc_type, d.description
HAVING SUM(COALESCE(el.debit_amount, 0))
     <> SUM(COALESCE(el.credit_amount, 0))
ORDER BY d.document_id;

\echo ''
\echo '=== Документы без строк журнала (тоже аномалия) ==='

SELECT
    d.document_id,
    d.operating_day,
    d.doc_type,
    d.description
FROM documents d
JOIN journal_entries je ON je.document_id = d.document_id
WHERE NOT EXISTS (
    SELECT 1 FROM entry_lines el WHERE el.entry_id = je.entry_id
)
ORDER BY d.document_id;
