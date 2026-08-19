-- ============================================================================
-- trial_balance.sql — пробный баланс (свод по лицевым счетам) на дату
-- ============================================================================
-- Пробный баланс — главный контроль двойной записи: сумма всех дебетовых
-- сальдо обязана равняться сумме всех кредитовых сальдо.
--
-- Запуск из psql:
--   psql ... -v as_of='2026-01-07' -f db/queries/trial_balance.sql
-- ============================================================================

\echo ''
\echo '=== Пробный баланс на' :as_of '==='

SELECT
    tb.account_number,
    tb.account_name,
    tb.currency,
    tb.turnover_debit,
    tb.turnover_credit,
    tb.closing_debit,
    tb.closing_credit
FROM trial_balance(:'as_of'::date) tb
WHERE tb.turnover_debit <> 0 OR tb.turnover_credit <> 0
   OR tb.closing_debit <> 0 OR tb.closing_credit <> 0
ORDER BY tb.account_number;

\echo ''
\echo '=== Контроль: сумма дебетовых и кредитовых сальдо ==='

SELECT
    SUM(tb.closing_debit)  AS total_debit,
    SUM(tb.closing_credit) AS total_credit,
    SUM(tb.closing_debit) - SUM(tb.closing_credit) AS imbalance
FROM trial_balance(:'as_of'::date) tb;
-- imbalance всегда 0.00, иначе где-то сломана двойная запись
