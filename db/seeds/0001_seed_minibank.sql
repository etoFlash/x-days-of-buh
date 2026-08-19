-- ============================================================================
-- 0001_seed_minibank.sql — стартовые данные «Mini Bank»
-- ============================================================================
-- Идемпотентно (ON CONFLICT DO NOTHING). Для чистого пересоздания:
--   TRUNCATE entry_lines, journal_entries, documents, close_of_day_runs,
--            personal_accounts, fx_rates, operating_days,
--            chart_of_accounts, customers, products RESTART IDENTITY CASCADE;
-- Все клиенты — синтетические. Никаких реальных ФИО, ИНН, карт, IBAN.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- План счетов Mini Bank (упрощённая учебная нумерация, вдохновлённая
-- банковской логикой; маппинг на реальность — в docs/assumptions.md)
-- ---------------------------------------------------------------------------
INSERT INTO chart_of_accounts (account_number, account_name, account_type, currency) VALUES
    -- Капитал
    ('10207', 'Уставный капитал банка',             'equity',   'RUB'),
    -- Актив: кредиты и резервы
    ('45205', 'Кредиты физическим лицам',           'asset',    'RUB'),
    ('45215', 'Резервы под кредиты физлиц (контр-актив)', 'asset', 'RUB'),
    -- Актив: корсчета в других банках
    ('30110', 'Корсчета в банках-корреспондентах (ностро RUB)', 'asset', 'RUB'),
    ('30114', 'Корсчета в банках-корреспондентах (ностро USD)', 'asset', 'USD'),
    -- Пассив: средства клиентов
    ('40817', 'Текущие счета физических лиц',       'liability', 'RUB'),
    ('40820', 'Текущие счета физлиц в иностранной валюте', 'liability', 'USD'),
    ('42301', 'Вклады (депозиты) физических лиц',   'liability', 'RUB'),
    -- Актив: касса
    ('20202', 'Касса банка в рублях',               'asset',    'RUB'),
    ('20206', 'Касса банка в иностранной валюте',   'asset',    'USD'),
    -- Внебаланс
    ('91305', 'Выданные гарантии и поручительства', 'off_balance', 'RUB'),
    -- Доходы и расходы (символы ОПУ)
    ('70601', 'Процентные доходы по кредитам',      'income',   'RUB'),
    ('70606', 'Процентные расходы по вкладам',      'expense',  'RUB'),
    ('70611', 'Комиссионные доходы',                'income',   'RUB'),
    ('70612', 'Расходы на создание резервов',       'expense',  'RUB'),
    ('70613', 'Доходы от переоценки валюты',        'income',   'RUB'),
    ('70614', 'Расходы от переоценки валюты',       'expense',  'RUB'),
    -- Технический счёт курсовой разницы при конверсии
    ('47423', 'Курсовые разницы при конверсии (образ. 47423)', 'liability', 'RUB')
ON CONFLICT (account_number) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Клиенты (синтетика!)
-- ---------------------------------------------------------------------------
INSERT INTO customers (customer_code, full_name, customer_type) VALUES
    ('CUST-001', 'Иванова Анна Сергеевна (синтетика)',  'individual'),
    ('CUST-002', 'Петров Пётр Иванович (синтетика)',    'individual'),
    ('CUST-003', 'Сидорова Ольга Петровна (синтетика)', 'individual')
ON CONFLICT (customer_code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Продукты
-- ---------------------------------------------------------------------------
INSERT INTO products (product_code, product_name, interest_rate) VALUES
    ('current', 'Текущий счёт физлица',          NULL),
    ('deposit', 'Срочный вклад, 6.5% годовых',   6.5000),
    ('loan',    'Потребительский кредит, 18% годовых', 18.0000),
    ('nostro',  'Корсчёт в банке-корреспонденте', NULL)
ON CONFLICT (product_code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Операционные дни.
-- Первый день банка (05.01) открывается, в конце seed'а закрывается после
-- проведения вступительных остатков — инвариант «закрытый день» работает
-- и на наших собственных данных. 06.01 — закрытый день без операций
-- (контрольный для переоценки и остатков на дату). Рабочий день — 07.01.
-- ---------------------------------------------------------------------------
INSERT INTO operating_days (operating_day, status) VALUES
    ('2026-01-05', 'open'),
    ('2026-01-07', 'open')
ON CONFLICT (operating_day) DO NOTHING;

INSERT INTO operating_days (operating_day, status, closed_at, closed_by) VALUES
    ('2026-01-06', 'closed', '2026-01-06 18:00:00+00', 'seed')
ON CONFLICT (operating_day) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Курсы валют (RUB за 1 USD) на 3 даты
-- ---------------------------------------------------------------------------
INSERT INTO fx_rates (rate_date, currency, rate_to_rub) VALUES
    ('2026-01-05', 'RUB', 1),
    ('2026-01-05', 'USD', 90.00),
    ('2026-01-06', 'USD', 91.50),
    ('2026-01-07', 'USD', 92.40)
ON CONFLICT (rate_date, currency) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Лицевые счета
-- ---------------------------------------------------------------------------
-- Счета самого банка (customer_id IS NULL): касса и ностро
INSERT INTO personal_accounts
    (account_number, coa_number, customer_id, product_code, currency, opened_on) VALUES
    ('20202.810.00000000001', '20202', NULL, NULL,    'RUB', '2026-01-05'),  -- касса RUB
    ('20206.840.00000000001', '20206', NULL, NULL,    'USD', '2026-01-05'),  -- касса USD
    ('30110.810.00000000001', '30110', NULL, 'nostro', 'RUB', '2026-01-05'), -- ностро RUB
    ('30114.840.00000000001', '30114', NULL, 'nostro', 'USD', '2026-01-05'), -- ностро USD
    ('47423.810.00000000001', '47423', NULL, NULL,    'RUB', '2026-01-05'),  -- курсовые разницы
    ('10207.810.00000000001', '10207', NULL, NULL,    'RUB', '2026-01-05')   -- уставный капитал
ON CONFLICT (account_number) DO NOTHING;

-- Счета клиентов (клиент определяется по коду)
INSERT INTO personal_accounts
    (account_number, coa_number, customer_id, product_code, currency, opened_on)
SELECT '40817.810.00000000001', '40817', c.customer_id, 'current', 'RUB', '2026-01-05'
FROM customers c WHERE c.customer_code = 'CUST-001'
ON CONFLICT (account_number) DO NOTHING;

INSERT INTO personal_accounts
    (account_number, coa_number, customer_id, product_code, currency, opened_on)
SELECT '40820.840.00000000002', '40820', c.customer_id, 'current', 'USD', '2026-01-05'
FROM customers c WHERE c.customer_code = 'CUST-001'
ON CONFLICT (account_number) DO NOTHING;

INSERT INTO personal_accounts
    (account_number, coa_number, customer_id, product_code, currency, opened_on)
SELECT '42301.810.00000000001', '42301', c.customer_id, 'deposit', 'RUB', '2026-01-05'
FROM customers c WHERE c.customer_code = 'CUST-002'
ON CONFLICT (account_number) DO NOTHING;

INSERT INTO personal_accounts
    (account_number, coa_number, customer_id, product_code, currency, opened_on)
SELECT '40817.810.00000000003', '40817', c.customer_id, 'current', 'RUB', '2026-01-05'
FROM customers c WHERE c.customer_code = 'CUST-003'
ON CONFLICT (account_number) DO NOTHING;

INSERT INTO personal_accounts
    (account_number, coa_number, customer_id, product_code, currency, opened_on)
SELECT '45205.810.00000000003', '45205', c.customer_id, 'loan',    'RUB', '2026-01-05'
FROM customers c WHERE c.customer_code = 'CUST-003'
ON CONFLICT (account_number) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Открывающие балансы на начало первого операционного дня (история):
--   1) формирование уставного капитала: Дт ностро RUB — Кт капитал;
--   2) обналичивание части средств в кассу (для выдач наличными).
-- Остатки остальных счетов «рождаются» из операций (модуль 01 и далее).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_doc bigint;
    v_entry bigint;
BEGIN
    IF EXISTS (SELECT 1 FROM journal_entries) THEN
        RETURN;  -- история уже загружена
    END IF;

    -- 1) Уставный капитал: 10 000 000 RUB на ностро
    INSERT INTO documents (operating_day, doc_type, description)
    VALUES ('2026-01-05', 'opening_balance', 'Взнос уставного капитала на корсчёт')
    RETURNING document_id INTO v_doc;

    INSERT INTO journal_entries (document_id, entry_date, description)
    VALUES (v_doc, '2026-01-05', 'Дт 30110 Ностро — Кт 10207 Уставный капитал')
    RETURNING entry_id INTO v_entry;

    INSERT INTO entry_lines (entry_id, account_id, debit_amount, line_no)
    SELECT v_entry, account_id, 10000000.00, 1
    FROM personal_accounts WHERE account_number = '30110.810.00000000001';

    INSERT INTO entry_lines (entry_id, account_id, credit_amount, line_no)
    SELECT v_entry, account_id, 10000000.00, 2
    FROM personal_accounts WHERE account_number = '10207.810.00000000001';

    -- 2) Снятие с ностро в кассу: 2 000 000 RUB
    INSERT INTO documents (operating_day, doc_type, description)
    VALUES ('2026-01-05', 'cash_replenishment', 'Подкрепление кассы с корсчёта')
    RETURNING document_id INTO v_doc;

    INSERT INTO journal_entries (document_id, entry_date, description)
    VALUES (v_doc, '2026-01-05', 'Дт 20202 Касса — Кт 30110 Ностро')
    RETURNING entry_id INTO v_entry;

    INSERT INTO entry_lines (entry_id, account_id, debit_amount, line_no)
    SELECT v_entry, account_id, 2000000.00, 1
    FROM personal_accounts WHERE account_number = '20202.810.00000000001';

    INSERT INTO entry_lines (entry_id, account_id, credit_amount, line_no)
    SELECT v_entry, account_id, 2000000.00, 2
    FROM personal_accounts WHERE account_number = '30110.810.00000000001';

    -- 3) Завоз 5 000 USD в валютную кассу с ностро USD (курс дня 90.00)
    --    Валютная сумма — в amount_currency, рублёвый эквивалент — в amount.
    INSERT INTO documents (operating_day, doc_type, description)
    VALUES ('2026-01-05', 'cash_replenishment',
            'Завоз наличной валюты в кассу с ностро USD')
    RETURNING document_id INTO v_doc;

    INSERT INTO journal_entries (document_id, entry_date, description)
    VALUES (v_doc, '2026-01-05',
            'Дт 20206 Касса USD — Кт 30114 Ностро USD, 5 000 USD по 90.00')
    RETURNING entry_id INTO v_entry;

    INSERT INTO entry_lines
        (entry_id, account_id, debit_amount, amount_currency, line_no)
    SELECT v_entry, account_id, 450000.00, 5000.00, 1
    FROM personal_accounts WHERE account_number = '20206.840.00000000001';

    INSERT INTO entry_lines
        (entry_id, account_id, credit_amount, amount_currency, line_no)
    SELECT v_entry, account_id, 450000.00, 5000.00, 2
    FROM personal_accounts WHERE account_number = '30114.840.00000000001';

    -- Контроль и закрытие первого операционного дня (как close-of-day в банке)
    PERFORM 1 FROM journal_entries;  -- день непустой
    UPDATE operating_days
    SET status = 'closed',
        closed_at = '2026-01-05 18:00:00+00',
        closed_by = 'seed'
    WHERE operating_day = '2026-01-05';
END $$;
