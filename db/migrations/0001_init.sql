-- ============================================================================
-- 0001_init.sql — ядро главной книги учебного банка «Mini Bank»
-- ============================================================================
-- Идемпотентно: скрипт можно выполнять повторно (IF NOT EXISTS / OR REPLACE).
--
-- Соглашения:
--   * функциональная валюта — RUB, вторая валюта — USD;
--   * entry_lines.amount — ВСЕГДА в функциональной валюте (RUB).
--     Для валютных лицевых счетов валютная сумма хранится в amount_currency,
--     рублёвый эквивалент — в amount (по курсу операционного дня);
--   * сальдо лицевого счёта НИГДЕ не хранится как «единственная правда» —
--     оно вычисляется из журнала проводок (см. представления в конце файла).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Справочники
-- ---------------------------------------------------------------------------

-- План счетов банка (синтетика). Упрощённая нумерация, вдохновлённая
-- банковской логикой: 1xx — капитал, 2xx — кредиты, 3xx — корсчета,
-- 4xx — счета клиентов и касса, 6xx — внебаланс, 7xx — доходы и расходы.
CREATE TABLE IF NOT EXISTS chart_of_accounts (
    account_number   text        PRIMARY KEY,
    account_name     text        NOT NULL,
    account_type     text        NOT NULL
                     CHECK (account_type IN
                            ('asset', 'liability', 'equity', 'income', 'expense', 'off_balance')),
    currency         char(3)     NOT NULL DEFAULT 'RUB',
    parent_number    text        REFERENCES chart_of_accounts (account_number),
    is_active        boolean     NOT NULL DEFAULT true,
    -- Увеличение типичного сальдо: 'debit' для активов/расходов/внебаланса,
    -- 'credit' для пассивов/капитала/доходов.
    normal_side      text        GENERATED ALWAYS AS (
                         CASE
                             WHEN account_type IN ('asset', 'expense', 'off_balance')
                             THEN 'debit'
                             ELSE 'credit'
                         END) STORED,
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS customers (
    customer_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_type    text        NOT NULL DEFAULT 'individual'
                     CHECK (customer_type IN ('individual', 'corporate')),
    customer_code    text        NOT NULL UNIQUE,   -- учебный код, не реальные персональные данные
    full_name        text        NOT NULL,          -- только синтетические имена
    created_at       timestamptz NOT NULL DEFAULT now()
);

-- Банковские продукты (типы договоров).
CREATE TABLE IF NOT EXISTS products (
    product_code     text        PRIMARY KEY,       -- 'current', 'deposit', 'loan', 'nostro'
    product_name     text        NOT NULL,
    interest_rate    numeric(7,4),                  -- годовая ставка, % (для вкладов/кредитов)
    created_at       timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 2. Лицевые счета (аналитика)
-- ---------------------------------------------------------------------------

-- Лицевой счёт — конкретный счёт конкретного клиента/объекта внутри
-- синтетического счёта плана. Пары банка (касса, ностро) заводим как
-- лицевые счета без клиента (customer_id IS NULL).
CREATE TABLE IF NOT EXISTS personal_accounts (
    account_id       bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_number   text        NOT NULL UNIQUE,   -- напр. '40817.810.00000000001'
    coa_number       text        NOT NULL REFERENCES chart_of_accounts (account_number),
    customer_id      bigint      REFERENCES customers (customer_id),
    product_code     text        REFERENCES products (product_code),
    currency         char(3)     NOT NULL DEFAULT 'RUB',
    opened_on        date        NOT NULL,
    closed_on        date,
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_personal_accounts_coa
    ON personal_accounts (coa_number);
CREATE INDEX IF NOT EXISTS idx_personal_accounts_customer
    ON personal_accounts (customer_id);

-- Курсы валют к функциональной (RUB за 1 единицу валюты).
CREATE TABLE IF NOT EXISTS fx_rates (
    rate_date        date        NOT NULL,
    currency         char(3)     NOT NULL,
    rate_to_rub      numeric(18,6) NOT NULL CHECK (rate_to_rub > 0),
    PRIMARY KEY (rate_date, currency)
);

-- ---------------------------------------------------------------------------
-- 3. Операционный день, документы, журнал
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS operating_days (
    operating_day    date        PRIMARY KEY,
    status           text        NOT NULL DEFAULT 'open'
                     CHECK (status IN ('open', 'closed')),
    closed_at        timestamptz,
    closed_by        text
);

-- Заголовок бухгалтерского документа (мемориальный ордер и т.п.).
CREATE TABLE IF NOT EXISTS documents (
    document_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operating_day    date        NOT NULL REFERENCES operating_days (operating_day),
    doc_type         text        NOT NULL,          -- 'payment', 'cash_in', 'loan_issue', ...
    description      text        NOT NULL,          -- человекочитаемое назначение
    external_ref     text,
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_documents_day ON documents (operating_day);

-- Запись журнала = документ (заголовок + дата); строки — в entry_lines.
CREATE TABLE IF NOT EXISTS journal_entries (
    entry_id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_id      bigint      NOT NULL UNIQUE REFERENCES documents (document_id),
    entry_date       date        NOT NULL,          -- дата отражения = операционный день
    description      text        NOT NULL,
    status           text        NOT NULL DEFAULT 'posted'
                     CHECK (status IN ('posted', 'reversed')),
    created_at       timestamptz NOT NULL DEFAULT now()
);

-- Строка проводки: одна сторона (дебет ИЛИ кредит) одного лицевого счёта.
CREATE TABLE IF NOT EXISTS entry_lines (
    entry_line_id    bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entry_id         bigint      NOT NULL REFERENCES journal_entries (entry_id),
    account_id       bigint      NOT NULL REFERENCES personal_accounts (account_id),
    debit_amount     numeric(18,2),
    credit_amount    numeric(18,2),
    currency         char(3)     NOT NULL DEFAULT 'RUB',  -- валюта лицевого счёта
    -- Валютная сумма: заполняется для счетов в иностранной валюте.
    amount_currency  numeric(18,2),
    line_no          integer     NOT NULL DEFAULT 1,
    CHECK ( (debit_amount IS NULL) <> (credit_amount IS NULL) ),  -- строго одна сторона
    CHECK (debit_amount  IS NULL OR debit_amount  > 0),
    CHECK (credit_amount IS NULL OR credit_amount > 0)
);

CREATE INDEX IF NOT EXISTS idx_entry_lines_entry   ON entry_lines (entry_id);
CREATE INDEX IF NOT EXISTS idx_entry_lines_account ON entry_lines (account_id);

-- Запуски процедуры закрытия операционного дня (аудит контролей).
CREATE TABLE IF NOT EXISTS close_of_day_runs (
    run_id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operating_day    date        NOT NULL REFERENCES operating_days (operating_day),
    started_at       timestamptz NOT NULL DEFAULT now(),
    finished_at      timestamptz,
    status           text        NOT NULL DEFAULT 'running'
                     CHECK (status IN ('running', 'success', 'failed')),
    checks_passed    integer     NOT NULL DEFAULT 0,
    checks_failed    integer     NOT NULL DEFAULT 0,
    details          jsonb
);

-- ---------------------------------------------------------------------------
-- 4. Триггеры-инварианты (SQL — источник истины)
-- ---------------------------------------------------------------------------

-- 4.1. Документ нельзя завести в закрытый операционный день.
CREATE OR REPLACE FUNCTION check_operating_day_open() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_status text;
BEGIN
    SELECT status INTO v_status
    FROM operating_days
    WHERE operating_day = NEW.operating_day;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Операционный день % не заведён в справочнике', NEW.operating_day;
    END IF;
    IF v_status <> 'open' THEN
        RAISE EXCEPTION 'Операционный день % закрыт: документ запрещён', NEW.operating_day;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_documents_day_open ON documents;
CREATE TRIGGER trg_documents_day_open
    BEFORE INSERT OR UPDATE OF operating_day ON documents
    FOR EACH ROW EXECUTE FUNCTION check_operating_day_open();

-- 4.2. Дата проводки = операционный день документа (не даём разъехаться).
CREATE OR REPLACE FUNCTION check_entry_date_matches_document() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_day date;
BEGIN
    SELECT operating_day INTO v_day
    FROM documents
    WHERE document_id = NEW.document_id;

    IF NEW.entry_date <> v_day THEN
        RAISE EXCEPTION 'entry_date % не совпадает с операционным днём документа %',
            NEW.entry_date, v_day;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_entries_date ON journal_entries;
CREATE TRIGGER trg_entries_date
    BEFORE INSERT OR UPDATE ON journal_entries
    FOR EACH ROW EXECUTE FUNCTION check_entry_date_matches_document();

-- 4.3. Двойная запись: сумма дебетов = сумма кредитов в каждой записи.
-- DEFERRABLE: проверка откладывается на COMMIT, чтобы внутри транзакции
-- можно было вставлять строки по одной.
CREATE OR REPLACE FUNCTION check_entry_balance() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_entry_id bigint := COALESCE(NEW.entry_id, OLD.entry_id);
    v_debit    numeric;
    v_credit   numeric;
BEGIN
    SELECT COALESCE(SUM(debit_amount), 0), COALESCE(SUM(credit_amount), 0)
      INTO v_debit, v_credit
    FROM entry_lines
    WHERE entry_id = v_entry_id;

    IF v_debit <> v_credit THEN
        RAISE EXCEPTION 'Проводка % не сбалансирована: дебет % <> кредит %',
            v_entry_id, v_debit, v_credit;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_entry_lines_balance ON entry_lines;
CREATE CONSTRAINT TRIGGER trg_entry_lines_balance
    AFTER INSERT OR UPDATE OR DELETE ON entry_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_entry_balance();

-- ---------------------------------------------------------------------------
-- 5. Витрины отчётности (функция + представления; физтаблица — модуль 08)
-- ---------------------------------------------------------------------------

-- Оборотно-сальдовая ведомость на дату по лицевым счетам.
-- Обороты — накопительно с начала учёта по дату включительно.
-- Сальдо — свёрнутое: дебетовое ИЛИ кредитовое по каждому лицевому счёту.
CREATE OR REPLACE FUNCTION trial_balance(as_of date)
RETURNS TABLE (
    account_number  text,
    currency        char(3),
    account_name    text,
    account_type    text,
    turnover_debit  numeric,
    turnover_credit numeric,
    closing_debit   numeric,
    closing_credit  numeric
)
LANGUAGE sql STABLE AS $$
    SELECT
        pa.account_number,
        pa.currency,
        coa.account_name,
        coa.account_type,
        COALESCE(SUM(el.debit_amount), 0),
        COALESCE(SUM(el.credit_amount), 0),
        GREATEST(COALESCE(SUM(el.debit_amount), 0)
                 - COALESCE(SUM(el.credit_amount), 0), 0),
        GREATEST(COALESCE(SUM(el.credit_amount), 0)
                 - COALESCE(SUM(el.debit_amount), 0), 0)
    FROM personal_accounts pa
    JOIN chart_of_accounts coa ON coa.account_number = pa.coa_number
    LEFT JOIN entry_lines      el ON el.account_id = pa.account_id
    LEFT JOIN journal_entries  je ON je.entry_id = el.entry_id
                                 AND je.status = 'posted'
                                 AND je.entry_date <= as_of
    GROUP BY pa.account_number, pa.currency,
             coa.account_name, coa.account_type
$$;

-- Дневная витрина движений по лицевым счетам (витрина, не физтаблица).
CREATE OR REPLACE VIEW v_balances_daily AS
SELECT
    je.entry_date AS balance_date,
    pa.account_id,
    pa.account_number,
    pa.currency,
    SUM(el.debit_amount) - SUM(el.credit_amount) AS movement_signed
FROM entry_lines el
JOIN journal_entries je ON je.entry_id = el.entry_id AND je.status = 'posted'
JOIN personal_accounts pa ON pa.account_id = el.account_id
GROUP BY je.entry_date, pa.account_id, pa.account_number, pa.currency;
