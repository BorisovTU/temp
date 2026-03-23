
FUNCTION AddReceiptInfoReportMetaUi
RETURN CLOB
IS
  C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
C_REPORT_LOCALIZED_NAME VARCHAR2(256)  := 'Добавление квитанции к отчету контроля за статусами и сроками предоставления отчетности в БР';
C_SYS_TAGS              VARCHAR2(256) := '["ORACLE_DEBUG", "BR"]';
v_meta_ui               CLOB;
BEGIN

    SELECT JSON_OBJECT(
                   'roles'   VALUE C_ROLES FORMAT JSON,
                   'label'   VALUE C_REPORT_LOCALIZED_NAME,
                   'sysTags' VALUE C_SYS_TAGS FORMAT JSON,
                   'form'    VALUE JSON_ARRAY(
                           JSON_ARRAY(
                                   JSON_OBJECT(
                                           'label'    VALUE 'Файл квитанции',
                                           'name'     VALUE 'ReceiptFile',
                                           'type'     VALUE 'file',
                                           'accept'   VALUE '*.xml',
                                           'required' VALUE 'true' FORMAT JSON,
                                           'column'   VALUE 0,
                                           'default'  VALUE ''
                                   )
                           )
                                   ) RETURNING CLOB
           )
    INTO v_meta_ui
    FROM dual;

    RETURN v_meta_ui;
END AddReceiptInfoReportMetaUi;

/**
 * Обрабатывает входящие квитанции и исходные ЭС от БР.
 *
 * Соответствует таблице кейсов "обработка квитанций.xlsx"
 *
 * Особенности:
 * - ИЭС1/ИЭС2: КодФормы сохраняется как есть из XML (с ведущими нулями, например '0409711')
 * - ИЭС1/ИЭС2: обновление ТОЛЬКО если T_STATUS IS NULL AND (T_MESSAGE IS NULL OR пустой)
 * - SOAP/Status:
 *   * T_FORM всегда = 'admission_procedure'
 *   * T_LIMITDATE = TRUNC(дата_квитанции)
 *   * Обновление ТОЛЬКО записей с T_STATUS IS NULL
 *   * При отсутствии подходящей записи ? INSERT новой
 *   * Для Status: заполняется только T_REGDATE, T_SENDDAY = NULL
 *   * Для SOAP: заполняется только T_SENDDAY, T_REGDATE = NULL
 * - Обработка ошибки уникального ограничения: "данная квитанция уже загружалась"
 */
FUNCTION AddReceiptInfo_RC_ReportRun(
  p_trace_id_input VARCHAR2,
  p_json_input     CLOB,
  p_is_production  CHAR DEFAULT '1'
) RETURN CLOB
IS
  PRAGMA AUTONOMOUS_TRANSACTION;

C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := 'limit_day_report';
C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := 'control_dates_report_';
C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'GetLmitDayReport';
C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'LimitDay_info';
C_OUTPUT_FILE_NAME_PRE  CONSTANT VARCHAR2(128) := 'Квитанции_БР';
C_ERR_99_CODE           CONSTANT VARCHAR2(8)   := 'ER_99';
C_ERR_99_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог обработать квитанцию: ошибка';
C_EMPTY_JSON_ARRAY      CONSTANT CLOB := TO_CLOB('[]');
C_ERR_UNIQUE_CODE       CONSTANT VARCHAR2(8)   := 'ER_01';  -- Код ошибки уникальности

v_xml_content           CLOB;
v_xml                   XMLTYPE;
v_result_array          JSON_ARRAY_T := JSON_ARRAY_T();
v_json_output           CLOB;
v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
v_correlation_id        VARCHAR2(64);
v_result_text           VARCHAR2(64);
v_create_time           TIMESTAMP;
v_reg_num               VARCHAR2(64);
v_status                VARCHAR2(512);
v_date_time             TIMESTAMP;
v_is_soap              BOOLEAN := FALSE;
v_is_status             BOOLEAN := FALSE;
v_is_ies1              BOOLEAN := FALSE;
v_is_ies2              BOOLEAN := FALSE;
v_log_prefix            VARCHAR2(256);
BEGIN
    v_log_prefix := 'AddReceiptInfoReport AddReceiptInfo_RC_ReportRun traceId=''' || COALESCE(p_trace_id_input, 'NULL') || '''';

    -- === ЛОГИРОВАНИЕ ВХОДНОГО JSON ===
    it_log.log(v_log_prefix || ' Input p_json_input (first 2000 chars): ' || DBMS_LOB.SUBSTR(p_json_input, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
    it_log.log(v_log_prefix || ' >>> FUNCTION STARTED <<<', it_log.C_MSG_TYPE__DEBUG);

    -- === ШАГ 1: Валидация входных данных ===
    IF p_json_input IS NULL OR p_json_input = '{}' OR p_json_input = '[]' THEN
        it_log.log(v_log_prefix || ' Empty or trivial input, returning Meta UI', it_log.C_MSG_TYPE__DEBUG);
        v_json_output := BuildJsonOutput(p_body => AddReceiptInfoReportMetaUi());
        it_log.log(v_log_prefix || ' Returning (empty input): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
        RETURN v_json_output;
    END IF;

    -- === Извлекаем XML из ReceiptFile ===
    DECLARE
        v_json_obj JSON_OBJECT_T;
    BEGIN
        it_log.log(v_log_prefix || ' Attempting to parse input JSON', it_log.C_MSG_TYPE__DEBUG);
        v_json_obj := JSON_OBJECT_T.parse(p_json_input);

        it_log.log(v_log_prefix || ' Extracting "ReceiptFile" field', it_log.C_MSG_TYPE__DEBUG);
        DECLARE
            v_receipt_value JSON_ELEMENT_T;
        BEGIN
            v_receipt_value := v_json_obj.get('ReceiptFile');
            IF v_receipt_value.is_array THEN
                v_xml_content := JSON_ARRAY_T(v_receipt_value).get_string(0);
            ELSIF v_receipt_value.is_string THEN
                v_xml_content := v_receipt_value.to_string();
            ELSE
                RAISE_APPLICATION_ERROR(-20001, 'ReceiptFile must be a string or array of one string');
            END IF;
        END;

        IF v_xml_content IS NULL THEN
            RAISE NO_DATA_FOUND;
        END IF;

        -- Удаляем декларацию XML
        v_xml_content := REGEXP_REPLACE(v_xml_content, '^\s*<\?xml[^>]*>\s*', '', 1, 1, 'm');
        it_log.log(v_log_prefix || ' XML after removing declaration (first 500 chars): ' || DBMS_LOB.SUBSTR(v_xml_content, 500, 1), it_log.C_MSG_TYPE__DEBUG);

    EXCEPTION
        WHEN OTHERS THEN
            it_log.log(v_log_prefix || ' ERROR parsing JSON or missing ReceiptFile: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
            v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, 'Отсутствует файл квитанции (ReceiptFile) или некорректный JSON'));
            v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
            it_log.log(v_log_prefix || ' Returning (JSON parse error): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
            RETURN v_json_output;
    END;

    -- === Преобразуем в XML ===
    BEGIN
        it_log.log(v_log_prefix || ' Attempting to parse XML', it_log.C_MSG_TYPE__DEBUG);
        v_xml := XMLTYPE(v_xml_content);
        it_log.log(v_log_prefix || ' XML parsed successfully', it_log.C_MSG_TYPE__DEBUG);
    EXCEPTION
        WHEN OTHERS THEN
            it_log.log(v_log_prefix || ' ERROR parsing XML: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
            v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, 'Некорректный XML'));
            v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
            it_log.log(v_log_prefix || ' Returning (XML parse error): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
            RETURN v_json_output;
    END;

    -- === Определяем тип XML ===
    DECLARE
        v_count NUMBER;
    BEGIN
        it_log.log(v_log_prefix || ' Detecting XML type using local-name()...', it_log.C_MSG_TYPE__DEBUG);

        SELECT COUNT(*) INTO v_count FROM XMLTABLE('/*[local-name()="Envelope"]' PASSING v_xml);
        IF v_count > 0 THEN
            v_is_soap := TRUE;
            it_log.log(v_log_prefix || ' Detected type: SOAP', it_log.C_MSG_TYPE__DEBUG);
        ELSE
            SELECT COUNT(*) INTO v_count FROM XMLTABLE('/*[local-name()="Status"]' PASSING v_xml);
            IF v_count > 0 THEN
                v_is_status := TRUE;
                it_log.log(v_log_prefix || ' Detected type: Status', it_log.C_MSG_TYPE__DEBUG);
            ELSE
                SELECT COUNT(*) INTO v_count FROM XMLTABLE('/*[local-name()="ИЭС1"]' PASSING v_xml);
                IF v_count > 0 THEN
                    v_is_ies1 := TRUE;
                    it_log.log(v_log_prefix || ' Detected type: ИЭС1', it_log.C_MSG_TYPE__DEBUG);
                ELSE
                    SELECT COUNT(*) INTO v_count FROM XMLTABLE('/*[local-name()="ИЭС2"]' PASSING v_xml);
                    IF v_count > 0 THEN
                        v_is_ies2 := TRUE;
                        it_log.log(v_log_prefix || ' Detected type: ИЭС2', it_log.C_MSG_TYPE__DEBUG);
                    ELSE
                        it_log.log(v_log_prefix || ' ERROR: Unknown XML format', it_log.C_MSG_TYPE__DEBUG);
                        v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, 'Неизвестный формат квитанции'));
                        v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                        it_log.log(v_log_prefix || ' Returning (unknown XML): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
                        RETURN v_json_output;
                    END IF;
                END IF;
            END IF;
        END IF;
    END;

    -- === Обработка по типу ===
    IF v_is_soap THEN
        it_log.log(v_log_prefix || ' Processing SOAP receipt...', it_log.C_MSG_TYPE__DEBUG);
        DECLARE
            v_form_code   VARCHAR2(20);
            v_limit_date  DATE;
            v_send_day    DATE;
            v_reg_day     DATE;
            v_message     CLOB;
            v_limit_calc  DATE;
        BEGIN
            SELECT x.CorrelationMessageID, a.ResultText, TO_TIMESTAMP_TZ(x.CreateTime, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM')
            INTO v_correlation_id, v_result_text, v_create_time
            FROM XMLTABLE(
                         XMLNAMESPACES('http://www.w3.org/2003/05/soap-envelope' AS "env", 'urn:cbr-ru:msg:props:v1.3' AS "props"),
                         '/env:Envelope/env:Header/props:MessageInfo' PASSING v_xml
                         COLUMNS CorrelationMessageID VARCHAR2(64) PATH 'props:CorrelationMessageID',
                             CreateTime VARCHAR2(32) PATH 'props:CreateTime'
                 ) x
                     CROSS JOIN XMLTABLE(
                    XMLNAMESPACES('urn:cbr-ru:msg:props:v1.3' AS "props"),
                    '/props:AcknowledgementInfo' PASSING v_xml
                    COLUMNS ResultText VARCHAR2(64) PATH 'props:ResultText'
                                ) a;

            v_status := CASE LOWER(v_result_text)
                            WHEN 'delivered'   THEN 'загружено'
                            WHEN 'registered'  THEN 'зарегистрировано'
                            WHEN 'processing'  THEN 'принято в обработку'
                            ELSE v_result_text
                END;

            -- Расчёт контрольной даты (просто дата без времени)
            v_limit_calc := TRUNC(v_create_time);
            it_log.log(v_log_prefix || ' SOAP: CreateTime=' || TO_CHAR(v_create_time, 'YYYY-MM-DD HH24:MI:SS') || ', T_LIMITDATE=' || TO_CHAR(v_limit_calc, 'YYYY-MM-DD'), it_log.C_MSG_TYPE__DEBUG);

            -- Попытка обновить запись со статусом NULL (прямое сравнение DATE = DATE)
            UPDATE DBDUI_REPORTPOSTINFO_DBT
            SET T_SENDDAY = CAST(v_create_time AS DATE),
                T_STATUS = v_status
            WHERE T_FORM = 'admission_procedure'
              AND T_LIMITDATE = v_limit_calc
              AND T_STATUS IS NULL
            RETURNING T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE
            INTO v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message;

            IF SQL%ROWCOUNT > 0 THEN
                it_log.log(v_log_prefix || ' Updated existing SOAP record (T_STATUS was NULL)', it_log.C_MSG_TYPE__DEBUG);
            ELSE
                -- Вставка новой записи
                BEGIN
                    INSERT INTO DBDUI_REPORTPOSTINFO_DBT (
                        T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE, T_ADDTIME
                    ) VALUES (
                                 'admission_procedure',
                                 v_limit_calc,
                                 CAST(v_create_time AS DATE),
                                 NULL,
                                 v_status,
                                 NULL,
                                 SYSTIMESTAMP
                             ) RETURNING T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE
                    INTO v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message;
                    it_log.log(v_log_prefix || ' INSERTED new SOAP record', it_log.C_MSG_TYPE__DEBUG);
                EXCEPTION
                    WHEN DUP_VAL_ON_INDEX THEN
                        it_log.log(v_log_prefix || ' ERROR: Unique constraint violated - квитанция уже загружена', it_log.C_MSG_TYPE__DEBUG);
                        v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_UNIQUE_CODE, 'данная квитанция уже загружалась'));
                        v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                        it_log.log(v_log_prefix || ' Returning (duplicate): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
                        RETURN v_json_output;
                END;
            END IF;

            -- === ДИАГНОСТИКА ТИПОВ ДАННЫХ ===
            it_log.log(v_log_prefix || ' SOAP: Preparing JSON output...', it_log.C_MSG_TYPE__DEBUG);
            it_log.log(v_log_prefix || ' SOAP: v_form_code=''' || COALESCE(v_form_code, 'NULL') || '''', it_log.C_MSG_TYPE__DEBUG);
            it_log.log(v_log_prefix || ' SOAP: v_limit_date=''' || COALESCE(TO_CHAR(v_limit_date, 'YYYY-MM-DD'), 'NULL') || '''', it_log.C_MSG_TYPE__DEBUG);
            it_log.log(v_log_prefix || ' SOAP: v_send_day=''' || COALESCE(TO_CHAR(v_send_day, 'YYYY-MM-DD'), 'NULL') || '''', it_log.C_MSG_TYPE__DEBUG);
            it_log.log(v_log_prefix || ' SOAP: v_reg_day=''' || COALESCE(TO_CHAR(v_reg_day, 'YYYY-MM-DD'), 'NULL') || '''', it_log.C_MSG_TYPE__DEBUG);
            it_log.log(v_log_prefix || ' SOAP: v_status=''' || COALESCE(v_status, 'NULL') || '''', it_log.C_MSG_TYPE__DEBUG);
            it_log.log(v_log_prefix || ' SOAP: v_message IS ' || CASE WHEN v_message IS NULL THEN 'NULL' ELSE 'NOT NULL (length=' || DBMS_LOB.GETLENGTH(v_message) || ')' END, it_log.C_MSG_TYPE__DEBUG);

            DECLARE v_json_clob CLOB; BEGIN
                -- Используем явное преобразование к CLOB для поля mess
                SELECT JSON_OBJECT(
                               'report_form' VALUE v_form_code,
                               'lim_date'    VALUE CASE WHEN v_limit_date IS NOT NULL THEN TO_CHAR(v_limit_date, 'DD.MM.YYYY') ELSE '' END,
                               'send_day'    VALUE CASE WHEN v_send_day IS NOT NULL THEN TO_CHAR(v_send_day, 'DD.MM.YYYY') ELSE '' END,
                               'reg_day'     VALUE CASE WHEN v_reg_day IS NOT NULL THEN TO_CHAR(v_reg_day, 'DD.MM.YYYY') ELSE '' END,
                               'status'      VALUE v_status,
                               'mess'        VALUE TO_CLOB(NVL(v_message, '')),
                               'date'        VALUE '',  -- всегда пустая строка в успешном ответе
                               'date_end'    VALUE ''   -- всегда пустая строка в успешном ответе
                               RETURNING CLOB
                       )
                INTO v_json_clob FROM dual;
                v_result_array.append(JSON_OBJECT_T.parse(v_json_clob));
                it_log.log(v_log_prefix || ' SOAP: JSON output generated successfully', it_log.C_MSG_TYPE__DEBUG);
            EXCEPTION
                WHEN OTHERS THEN
                    it_log.log(v_log_prefix || ' SOAP: ERROR generating JSON: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
                    -- Безопасная диагностика без DUMP
                    BEGIN
                        IF v_message IS NOT NULL THEN
                            it_log.log(v_log_prefix || ' SOAP: v_message first 100 chars: ''' || DBMS_LOB.SUBSTR(v_message, 100, 1) || '''', it_log.C_MSG_TYPE__DEBUG);
                        ELSE
                            it_log.log(v_log_prefix || ' SOAP: v_message IS NULL', it_log.C_MSG_TYPE__DEBUG);
                        END IF;
                    EXCEPTION WHEN OTHERS THEN NULL; END;
                    RAISE;
            END;
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                it_log.log(v_log_prefix || ' ERROR: Unique constraint violated - квитанция уже загружена', it_log.C_MSG_TYPE__DEBUG);
                v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_UNIQUE_CODE, 'данная квитанция уже загружалась'));
                v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                it_log.log(v_log_prefix || ' Returning (duplicate): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
                RETURN v_json_output;
            WHEN OTHERS THEN
                it_log.log(v_log_prefix || ' ERROR during SOAP processing: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
                v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, 'Ошибка при обработке SOAP: ' || SQLERRM));
                v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                it_log.log(v_log_prefix || ' Returning (SOAP error): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
                RETURN v_json_output;
        END;

    ELSIF v_is_status THEN
        it_log.log(v_log_prefix || ' Processing Status receipt...', it_log.C_MSG_TYPE__DEBUG);
        DECLARE
            v_rowid       ROWID;
            v_form_code   VARCHAR2(20);
            v_limit_date  DATE;
            v_send_day    DATE;
            v_reg_day     DATE;
            v_message     CLOB;
            v_limit_calc  DATE;
        BEGIN
            SELECT x.regNum, x.status, TO_TIMESTAMP_TZ(x.dateTime, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM')
            INTO v_reg_num, v_result_text, v_date_time
            FROM XMLTABLE(
                         XMLNAMESPACES('http://www.cbr.ru/igr/' AS "igr"),
                         '/igr:Status' PASSING v_xml
                         COLUMNS regNum VARCHAR2(64) PATH 'igr:regNum', status VARCHAR2(64) PATH 'igr:status', dateTime VARCHAR2(32) PATH 'igr:dateTime'
                 ) x;

            v_status := CASE LOWER(v_result_text)
                            WHEN 'delivered'   THEN 'загружено'
                            WHEN 'registered'  THEN 'зарегистрировано'
                            WHEN 'processing'  THEN 'принято в обработку'
                            ELSE v_result_text
                END;

            v_limit_calc := TRUNC(v_date_time);
            it_log.log(v_log_prefix || ' Status: dateTime=' || TO_CHAR(v_date_time, 'YYYY-MM-DD HH24:MI:SS') || ', T_LIMITDATE=' || TO_CHAR(v_limit_calc, 'YYYY-MM-DD'), it_log.C_MSG_TYPE__DEBUG);

            -- Попытка обновить запись со статусом NULL (возвращаем только ROWID)
            UPDATE DBDUI_REPORTPOSTINFO_DBT
            SET T_REGDATE = CAST(v_date_time AS DATE),
                T_STATUS = v_status
            WHERE T_FORM = 'admission_procedure'
              AND T_LIMITDATE = v_limit_calc
              AND T_STATUS IS NULL
            RETURNING ROWID INTO v_rowid;

            IF SQL%ROWCOUNT > 0 THEN
                it_log.log(v_log_prefix || ' Updated existing Status record (T_STATUS was NULL)', it_log.C_MSG_TYPE__DEBUG);
                -- Получаем данные обновлённой строки отдельным запросом
                SELECT T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE
                INTO v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message
                FROM DBDUI_REPORTPOSTINFO_DBT
                WHERE ROWID = v_rowid;
            ELSE
                -- Вставка новой записи
                BEGIN
                    INSERT INTO DBDUI_REPORTPOSTINFO_DBT (
                        T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE, T_ADDTIME
                    ) VALUES (
                                 'admission_procedure',
                                 v_limit_calc,
                                 NULL,
                                 CAST(v_date_time AS DATE),
                                 v_status,
                                 NULL,
                                 SYSTIMESTAMP
                             ) RETURNING ROWID INTO v_rowid;
                    it_log.log(v_log_prefix || ' INSERTED new Status record', it_log.C_MSG_TYPE__DEBUG);
                    -- Получаем данные вставленной строки
                    SELECT T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE
                    INTO v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message
                    FROM DBDUI_REPORTPOSTINFO_DBT
                    WHERE ROWID = v_rowid;
                EXCEPTION
                    WHEN DUP_VAL_ON_INDEX THEN
                        it_log.log(v_log_prefix || ' ERROR: Unique constraint violated - квитанция уже загружена', it_log.C_MSG_TYPE__DEBUG);
                        v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_UNIQUE_CODE, 'данная квитанция уже загружалась'));
                        v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                        it_log.log(v_log_prefix || ' Returning (duplicate): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
                        RETURN v_json_output;
                END;
            END IF;

            -- Формируем результат (безопасное преобразование CLOB)
            DECLARE v_json_clob CLOB; BEGIN
                SELECT JSON_OBJECT(
                               'report_form' VALUE v_form_code,
                               'lim_date'    VALUE CASE WHEN v_limit_date IS NOT NULL THEN TO_CHAR(v_limit_date, 'DD.MM.YYYY') ELSE '' END,
                               'send_day'    VALUE CASE WHEN v_send_day IS NOT NULL THEN TO_CHAR(v_send_day, 'DD.MM.YYYY') ELSE '' END,
                               'reg_day'     VALUE CASE WHEN v_reg_day IS NOT NULL THEN TO_CHAR(v_reg_day, 'DD.MM.YYYY') ELSE '' END,
                               'status'      VALUE v_status,
                               'mess'        VALUE TO_CLOB(NVL(v_message, '')),
                               'date'        VALUE '',  -- всегда пустая строка в успешном ответе
                               'date_end'    VALUE ''   -- всегда пустая строка в успешном ответе
                               RETURNING CLOB
                       )
                INTO v_json_clob FROM dual;
                v_result_array.append(JSON_OBJECT_T.parse(v_json_clob));
                it_log.log(v_log_prefix || ' Status: JSON output generated successfully', it_log.C_MSG_TYPE__DEBUG);
            END;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                it_log.log(v_log_prefix || ' ERROR: ROWID not found after UPDATE/INSERT', it_log.C_MSG_TYPE__DEBUG);
                v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, 'Ошибка при получении данных после обновления'));
                v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                it_log.log(v_log_prefix || ' Returning (Status error): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
                RETURN v_json_output;
            WHEN DUP_VAL_ON_INDEX THEN
                it_log.log(v_log_prefix || ' ERROR: Unique constraint violated - квитанция уже загружена', it_log.C_MSG_TYPE__DEBUG);
                v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_UNIQUE_CODE, 'данная квитанция уже загружалась'));
                v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                it_log.log(v_log_prefix || ' Returning (duplicate): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
                RETURN v_json_output;
            WHEN OTHERS THEN
                it_log.log(v_log_prefix || ' ERROR during Status processing: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
                v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, 'Ошибка при обработке Status: ' || SQLERRM));
                v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                it_log.log(v_log_prefix || ' Returning (Status error): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
                RETURN v_json_output;
        END;

    ELSIF v_is_ies1 THEN
        it_log.log(v_log_prefix || ' Processing ИЭС1...', it_log.C_MSG_TYPE__DEBUG);
        BEGIN
            DECLARE
                v_form_code       VARCHAR2(20);
                v_send_time_str   VARCHAR2(32);
                v_reg_time_str    VARCHAR2(32);
                v_limit_time_str  VARCHAR2(32);
                v_message_detail  CLOB;
                v_send_time       TIMESTAMP;
                v_reg_time        TIMESTAMP;
                v_limit_time      TIMESTAMP;
                v_limit_date_db   DATE;
                v_existing_count  NUMBER := 0;
            BEGIN
                SELECT
                    x.form_code,
                    x.send_time,
                    x.reg_time,
                    x.limit_time,
                    x.result_control,
                    x.message_detail
                INTO
                    v_form_code, v_send_time_str, v_reg_time_str, v_limit_time_str, v_status, v_message_detail
                FROM XMLTABLE(
                             '/*[local-name()="ИЭС1"]'
                             PASSING v_xml
                             COLUMNS
                                 form_code       VARCHAR2(20)  PATH '*[local-name()="РеквОЭС"]/@КодФормы',
                                 send_time       VARCHAR2(32)  PATH '*[local-name()="РеквОЭС"]/@ДатаВремяФормирования',
                                 reg_time        VARCHAR2(32)  PATH '*[local-name()="РеквОЭС"]/@ДатаВремяРегистрации',
                                 limit_time      VARCHAR2(32)  PATH './@ДатаВремяКонтроля',
                                 result_control  VARCHAR2(512) PATH './@РезКонтроля',
                                 message_detail  CLOB          PATH '*[local-name()="ПротоколКонтроля"]/*[local-name()="Сообщение"]/text()'
                     ) x;

                it_log.log(v_log_prefix || ' ИЭС1: КодФормы=''' || v_form_code || ''', ДатаВремяКонтроля=''' || v_limit_time_str || '''', it_log.C_MSG_TYPE__DEBUG);

                IF v_send_time_str IS NOT NULL THEN v_send_time := TO_TIMESTAMP_TZ(v_send_time_str, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM'); END IF;
                IF v_reg_time_str IS NOT NULL THEN v_reg_time := TO_TIMESTAMP_TZ(v_reg_time_str, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM'); END IF;
                IF v_limit_time_str IS NOT NULL THEN v_limit_time := TO_TIMESTAMP_TZ(v_limit_time_str, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM'); END IF;

                -- Критическое исправление: используем прямое сравнение DATE = DATE (без TRUNC)
                v_limit_date_db := TRUNC(v_limit_time);
                it_log.log(v_log_prefix || ' ИЭС1: v_limit_date_db = ' || TO_CHAR(v_limit_date_db, 'YYYY-MM-DD'), it_log.C_MSG_TYPE__DEBUG);

                -- Поиск записи-заглушки (прямое сравнение DATE = DATE)
                SELECT COUNT(*) INTO v_existing_count
                FROM DBDUI_REPORTPOSTINFO_DBT
                WHERE T_FORM = v_form_code
                  AND T_LIMITDATE = v_limit_date_db
                  AND T_STATUS IS NULL
                  AND (T_MESSAGE IS NULL OR DBMS_LOB.GETLENGTH(T_MESSAGE) = 0);

                it_log.log(v_log_prefix || ' ИЭС1: count of stub records = ' || v_existing_count, it_log.C_MSG_TYPE__DEBUG);

                IF v_existing_count > 0 THEN
                    UPDATE DBDUI_REPORTPOSTINFO_DBT
                    SET T_SENDDAY = CAST(v_send_time AS DATE),
                        T_REGDATE = CAST(v_reg_time AS DATE),
                        T_STATUS = v_status,
                        T_MESSAGE = v_message_detail
                    WHERE T_FORM = v_form_code
                      AND T_LIMITDATE = v_limit_date_db
                      AND T_STATUS IS NULL
                      AND (T_MESSAGE IS NULL OR DBMS_LOB.GETLENGTH(T_MESSAGE) = 0);
                    it_log.log(v_log_prefix || ' ИЭС1: UPDATED existing stub record (form=' || v_form_code || ', limit_date=' || TO_CHAR(v_limit_date_db, 'YYYY-MM-DD') || ')', it_log.C_MSG_TYPE__DEBUG);
                ELSE
                    -- Вставка новой записи
                    BEGIN
                        INSERT INTO DBDUI_REPORTPOSTINFO_DBT (
                            T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE, T_ADDTIME
                        ) VALUES (
                                     v_form_code,
                                     v_limit_date_db,
                                     CAST(v_send_time AS DATE),
                                     CAST(v_reg_time AS DATE),
                                     v_status,
                                     v_message_detail,
                                     SYSTIMESTAMP
                                 );
                        it_log.log(v_log_prefix || ' ИЭС1: INSERTED new record (form=' || v_form_code || ', limit_date=' || TO_CHAR(v_limit_date_db, 'YYYY-MM-DD') || ')', it_log.C_MSG_TYPE__DEBUG);
                    EXCEPTION
                        WHEN DUP_VAL_ON_INDEX THEN
                            it_log.log(v_log_prefix || ' ERROR: Unique constraint violated - квитанция уже загружена', it_log.C_MSG_TYPE__DEBUG);
                            v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_UNIQUE_CODE, 'данная квитанция уже загружалась'));
                            v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                            it_log.log(v_log_prefix || ' Returning (duplicate): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
                            RETURN v_json_output;
                    END;
                END IF;

                -- === ДИАГНОСТИКА ТИПОВ ДАННЫХ ===
                it_log.log(v_log_prefix || ' ИЭС1: Preparing JSON output...', it_log.C_MSG_TYPE__DEBUG);
                it_log.log(v_log_prefix || ' ИЭС1: v_form_code=''' || COALESCE(v_form_code, 'NULL') || '''', it_log.C_MSG_TYPE__DEBUG);
                it_log.log(v_log_prefix || ' ИЭС1: v_status=''' || COALESCE(v_status, 'NULL') || '''', it_log.C_MSG_TYPE__DEBUG);
                it_log.log(v_log_prefix || ' ИЭС1: v_message_detail IS ' || CASE WHEN v_message_detail IS NULL THEN 'NULL' ELSE 'NOT NULL (length=' || DBMS_LOB.GETLENGTH(v_message_detail) || ')' END, it_log.C_MSG_TYPE__DEBUG);

                DECLARE v_json_clob CLOB; BEGIN
                    SELECT JSON_OBJECT(
                                   'report_form' VALUE v_form_code,
                                   'lim_date'    VALUE CASE WHEN v_limit_date_db IS NOT NULL THEN TO_CHAR(v_limit_date_db, 'DD.MM.YYYY') ELSE '' END,
                                   'send_day'    VALUE CASE WHEN v_send_time IS NOT NULL THEN TO_CHAR(v_send_time, 'DD.MM.YYYY') ELSE '' END,
                                   'reg_day'     VALUE CASE WHEN v_reg_time IS NOT NULL THEN TO_CHAR(v_reg_time, 'DD.MM.YYYY') ELSE '' END,
                                   'status'      VALUE v_status,
                                   'mess'        VALUE TO_CLOB(NVL(v_message_detail, '')),
                                   'date'        VALUE '',  -- всегда пустая строка в успешном ответе
                                   'date_end'    VALUE ''   -- всегда пустая строка в успешном ответе
                                   RETURNING CLOB
                           )
                    INTO v_json_clob FROM dual;
                    v_result_array.append(JSON_OBJECT_T.parse(v_json_clob));
                    it_log.log(v_log_prefix || ' ИЭС1: JSON output generated successfully', it_log.C_MSG_TYPE__DEBUG);
                EXCEPTION
                    WHEN OTHERS THEN
                        it_log.log(v_log_prefix || ' ИЭС1: ERROR generating JSON: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
                        -- Безопасная диагностика без DUMP
                        BEGIN
                            IF v_message_detail IS NOT NULL THEN
                                it_log.log(v_log_prefix || ' ИЭС1: v_message_detail first 100 chars: ''' || DBMS_LOB.SUBSTR(v_message_detail, 100, 1) || '''', it_log.C_MSG_TYPE__DEBUG);
                            ELSE
                                it_log.log(v_log_prefix || ' ИЭС1: v_message_detail IS NULL', it_log.C_MSG_TYPE__DEBUG);
                            END IF;
                        EXCEPTION WHEN OTHERS THEN NULL; END;
                        RAISE;
                END;
            END;
        EXCEPTION WHEN OTHERS THEN
            it_log.log(v_log_prefix || ' ERROR during ИЭС1 processing: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
            v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, 'Ошибка при обработке ИЭС1: ' || SQLERRM));
            v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
            it_log.log(v_log_prefix || ' Returning (ИЭС1 error): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
            RETURN v_json_output;
        END;

    ELSIF v_is_ies2 THEN
        it_log.log(v_log_prefix || ' Processing ИЭС2...', it_log.C_MSG_TYPE__DEBUG);
        BEGIN
            DECLARE
                v_form_code       VARCHAR2(20);
                v_send_time_str   VARCHAR2(32);
                v_reg_time_str    VARCHAR2(32);
                v_limit_time_str  VARCHAR2(32);
                v_message_detail  CLOB;
                v_send_time       TIMESTAMP;
                v_reg_time        TIMESTAMP;
                v_limit_time      TIMESTAMP;
                v_limit_date_db   DATE;
                v_existing_count  NUMBER := 0;
            BEGIN
                SELECT
                    r.form_code,
                    r.send_time,
                    r.reg_time,
                    r.limit_time,
                    r.result_control,
                    LISTAGG(m.msg, CHR(10)) WITHIN GROUP (ORDER BY m.msg)
                INTO
                    v_form_code, v_send_time_str, v_reg_time_str, v_limit_time_str, v_status, v_message_detail
                FROM XMLTABLE(
                             '/*[local-name()="ИЭС2"]'
                             PASSING v_xml
                             COLUMNS
                                 form_code       VARCHAR2(20)  PATH '*[local-name()="РеквОЭС"]/@КодФормы',
                                 send_time       VARCHAR2(32)  PATH '*[local-name()="РеквОЭС"]/@ДатаВремяФормирования',
                                 reg_time        VARCHAR2(32)  PATH '*[local-name()="РеквОЭС"]/@ДатаВремяРегистрации',
                                 limit_time      VARCHAR2(32)  PATH '*[local-name()="ДанныеОЭС"]/@ДатаВремяКонтроля',
                                 result_control  VARCHAR2(512) PATH '*[local-name()="ДанныеОЭС"]/@РезКонтроля'
                     ) r
                         CROSS JOIN XMLTABLE(
                        '/*[local-name()="ИЭС2"]/*[local-name()="ДанныеОЭС"]/*[local-name()="ПротоколКонтроля"]/*[local-name()="Сообщение"]'
                        PASSING v_xml
                        COLUMNS
                            msg VARCHAR2(4000) PATH '.'
                                    ) m
                GROUP BY r.form_code, r.send_time, r.reg_time, r.limit_time, r.result_control;

                it_log.log(v_log_prefix || ' ИЭС2: КодФормы=''' || v_form_code || ''', ДатаВремяКонтроля=''' || v_limit_time_str || '''', it_log.C_MSG_TYPE__DEBUG);
                it_log.log(v_log_prefix || ' ИЭС2: сообщений найдено = ' || CASE WHEN v_message_detail IS NOT NULL THEN LENGTH(v_message_detail) - LENGTH(REPLACE(v_message_detail, CHR(10), '')) + 1 ELSE 0 END, it_log.C_MSG_TYPE__DEBUG);

                IF v_send_time_str IS NOT NULL THEN v_send_time := TO_TIMESTAMP_TZ(v_send_time_str, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM'); END IF;
                IF v_reg_time_str IS NOT NULL THEN v_reg_time := TO_TIMESTAMP_TZ(v_reg_time_str, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM'); END IF;
                IF v_limit_time_str IS NOT NULL THEN v_limit_time := TO_TIMESTAMP_TZ(v_limit_time_str, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM'); END IF;

                -- Критическое исправление: используем прямое сравнение DATE = DATE (без TRUNC)
                v_limit_date_db := TRUNC(v_limit_time);
                it_log.log(v_log_prefix || ' ИЭС2: v_limit_date_db = ' || TO_CHAR(v_limit_date_db, 'YYYY-MM-DD'), it_log.C_MSG_TYPE__DEBUG);

                -- Поиск записи-заглушки (прямое сравнение DATE = DATE)
                SELECT COUNT(*) INTO v_existing_count
                FROM DBDUI_REPORTPOSTINFO_DBT
                WHERE T_FORM = v_form_code
                  AND T_LIMITDATE = v_limit_date_db
                  AND T_STATUS IS NULL
                  AND (T_MESSAGE IS NULL OR DBMS_LOB.GETLENGTH(T_MESSAGE) = 0);

                it_log.log(v_log_prefix || ' ИЭС2: count of stub records = ' || v_existing_count, it_log.C_MSG_TYPE__DEBUG);

                IF v_existing_count > 0 THEN
                    UPDATE DBDUI_REPORTPOSTINFO_DBT
                    SET T_SENDDAY = CAST(v_send_time AS DATE),
                        T_REGDATE = CAST(v_reg_time AS DATE),
                        T_STATUS = v_status,
                        T_MESSAGE = v_message_detail
                    WHERE T_FORM = v_form_code
                      AND T_LIMITDATE = v_limit_date_db
                      AND T_STATUS IS NULL
                      AND (T_MESSAGE IS NULL OR DBMS_LOB.GETLENGTH(T_MESSAGE) = 0);
                    it_log.log(v_log_prefix || ' ИЭС2: UPDATED existing stub record (form=' || v_form_code || ', limit_date=' || TO_CHAR(v_limit_date_db, 'YYYY-MM-DD') || ')', it_log.C_MSG_TYPE__DEBUG);
                ELSE
                    -- Вставка новой записи
                    BEGIN
                        INSERT INTO DBDUI_REPORTPOSTINFO_DBT (
                            T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE, T_ADDTIME
                        ) VALUES (
                                     v_form_code,
                                     v_limit_date_db,
                                     CAST(v_send_time AS DATE),
                                     CAST(v_reg_time AS DATE),
                                     v_status,
                                     v_message_detail,
                                     SYSTIMESTAMP
                                 );
                        it_log.log(v_log_prefix || ' ИЭС2: INSERTED new record (form=' || v_form_code || ', limit_date=' || TO_CHAR(v_limit_date_db, 'YYYY-MM-DD') || ')', it_log.C_MSG_TYPE__DEBUG);
                    EXCEPTION
                        WHEN DUP_VAL_ON_INDEX THEN
                            it_log.log(v_log_prefix || ' ERROR: Unique constraint violated - квитанция уже загружена', it_log.C_MSG_TYPE__DEBUG);
                            v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_UNIQUE_CODE, 'данная квитанция уже загружалась'));
                            v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                            it_log.log(v_log_prefix || ' Returning (duplicate): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
                            RETURN v_json_output;
                    END;
                END IF;

                -- === ДИАГНОСТИКА ТИПОВ ДАННЫХ ===
                it_log.log(v_log_prefix || ' ИЭС2: Preparing JSON output...', it_log.C_MSG_TYPE__DEBUG);
                it_log.log(v_log_prefix || ' ИЭС2: v_form_code=''' || COALESCE(v_form_code, 'NULL') || '''', it_log.C_MSG_TYPE__DEBUG);
                it_log.log(v_log_prefix || ' ИЭС2: v_status=''' || COALESCE(v_status, 'NULL') || '''', it_log.C_MSG_TYPE__DEBUG);
                it_log.log(v_log_prefix || ' ИЭС2: v_message_detail IS ' || CASE WHEN v_message_detail IS NULL THEN 'NULL' ELSE 'NOT NULL (length=' || DBMS_LOB.GETLENGTH(v_message_detail) || ')' END, it_log.C_MSG_TYPE__DEBUG);

                DECLARE v_json_clob CLOB; BEGIN
                    SELECT JSON_OBJECT(
                                   'report_form' VALUE v_form_code,
                                   'lim_date'    VALUE CASE WHEN v_limit_date_db IS NOT NULL THEN TO_CHAR(v_limit_date_db, 'DD.MM.YYYY') ELSE '' END,
                                   'send_day'    VALUE CASE WHEN v_send_time IS NOT NULL THEN TO_CHAR(v_send_time, 'DD.MM.YYYY') ELSE '' END,
                                   'reg_day'     VALUE CASE WHEN v_reg_time IS NOT NULL THEN TO_CHAR(v_reg_time, 'DD.MM.YYYY') ELSE '' END,
                                   'status'      VALUE v_status,
                                   'mess'        VALUE TO_CLOB(NVL(v_message_detail, '')),
                                   'date'        VALUE '',  -- всегда пустая строка в успешном ответе
                                   'date_end'    VALUE ''   -- всегда пустая строка в успешном ответе
                                   RETURNING CLOB
                           )
                    INTO v_json_clob FROM dual;
                    v_result_array.append(JSON_OBJECT_T.parse(v_json_clob));
                    it_log.log(v_log_prefix || ' ИЭС2: JSON output generated successfully', it_log.C_MSG_TYPE__DEBUG);
                EXCEPTION
                    WHEN OTHERS THEN
                        it_log.log(v_log_prefix || ' ИЭС2: ERROR generating JSON: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
                        -- Безопасная диагностика без DUMP
                        BEGIN
                            IF v_message_detail IS NOT NULL THEN
                                it_log.log(v_log_prefix || ' ИЭС2: v_message_detail first 100 chars: ''' || DBMS_LOB.SUBSTR(v_message_detail, 100, 1) || '''', it_log.C_MSG_TYPE__DEBUG);
                            ELSE
                                it_log.log(v_log_prefix || ' ИЭС2: v_message_detail IS NULL', it_log.C_MSG_TYPE__DEBUG);
                            END IF;
                        EXCEPTION WHEN OTHERS THEN NULL; END;
                        RAISE;
                END;
            END;
        EXCEPTION WHEN OTHERS THEN
            it_log.log(v_log_prefix || ' ERROR during ИЭС2 processing: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
            v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, 'Ошибка при обработке ИЭС2: ' || SQLERRM));
            v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
            it_log.log(v_log_prefix || ' Returning (ИЭС2 error): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1), it_log.C_MSG_TYPE__DEBUG);
            RETURN v_json_output;
        END;
    END IF;

    COMMIT;
    it_log.log(v_log_prefix || ' Transaction committed', it_log.C_MSG_TYPE__DEBUG);

    -- === Формируем результат ===
    v_json_output := v_result_array.to_clob();
    v_json_output := BuildSplitJsonOutput(
            p_trace_id_input => p_trace_id_input, p_json_input => v_json_output, p_report_date_input => SYSDATE,
            p_report_tag => C_REPORT_NAME_TAG, p_items_arr_tag => C_ITEMS_ARR_TAG, p_template_name => C_TEMPLATE_NAME,
            p_output_file_name => C_OUTPUT_FILE_NAME_PRE, p_s3_file_name => C_S3_FILE_NAME
                     );

    it_log.log(v_log_prefix || ' Final output (first 2000 chars): ' || DBMS_LOB.SUBSTR(COALESCE(v_json_output, TO_CLOB('NULL')), 2000, 1), it_log.C_MSG_TYPE__DEBUG);
    it_log.log(v_log_prefix || ' <<< FUNCTION COMPLETED SUCCESSFULLY >>>', it_log.C_MSG_TYPE__DEBUG);
    RETURN v_json_output;

EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        it_log.log(v_log_prefix || ' FATAL ERROR: Unique constraint violated - квитанция уже загружена', it_log.C_MSG_TYPE__DEBUG);
        v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_UNIQUE_CODE, 'данная квитанция уже загружалась'));
        v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
        it_log.log(v_log_prefix || ' Returning (duplicate exception): ' || DBMS_LOB.SUBSTR(COALESCE(v_json_output, TO_CLOB('NULL')), 2000, 1), it_log.C_MSG_TYPE__DEBUG);
        RETURN v_json_output;
    WHEN OTHERS THEN
        ROLLBACK;
        it_log.log(v_log_prefix || ' FATAL ERROR in function: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
        it_error.put_error_in_stack;
        v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, C_ERR_99_MSG || ': ' || SQLERRM));
        v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
        it_log.log(v_log_prefix || ' Returning (exception): ' || DBMS_LOB.SUBSTR(COALESCE(v_json_output, TO_CLOB('NULL')), 2000, 1), it_log.C_MSG_TYPE__DEBUG);
        RETURN v_json_output;
END AddReceiptInfo_RC_ReportRun;

