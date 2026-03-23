CREATE OR REPLACE PACKAGE BODY IT_CheckLimitReport AS

        FUNCTION ParseReceiptXml(
            p_json_input CLOB
        ) RETURN CLOB
            IS
            C_VALIDATION_ERROR CONSTANT VARCHAR2(50) := 'ReceiptFile. ошибка валидации.';
            C_EMPTY_JSON CONSTANT       VARCHAR2(50) := 'Содержимое квитанции отсутствует';
            C_WRONG_FORMAT CONSTANT     VARCHAR2(50) := 'ReceiptFile неверный формат';
            v_xml_content               CLOB;
            v_json_obj                  JSON_OBJECT_T;
            v_receipt_value             JSON_ELEMENT_T;
        BEGIN
            IF p_json_input IS NULL OR p_json_input = '{}' OR p_json_input = '[]' THEN
                RAISE_APPLICATION_ERROR(-20002, C_EMPTY_JSON);
            END IF;

            v_json_obj := JSON_OBJECT_T.parse(p_json_input);
            v_receipt_value := v_json_obj.get('ReceiptFile');

            IF v_receipt_value.is_array THEN
                v_xml_content := JSON_ARRAY_T(v_receipt_value).get_string(0);
            ELSIF v_receipt_value.is_string THEN
                v_xml_content := v_receipt_value.to_string();
            ELSE
                RAISE_APPLICATION_ERROR(-20001, C_WRONG_FORMAT);
            END IF;

            IF v_xml_content IS NULL THEN
                RAISE NO_DATA_FOUND;
            END IF;

            v_xml_content := REGEXP_REPLACE(v_xml_content, '^\s*<\?xml[^>]*>\s*', '', 1, 1, 'm');
            RETURN v_xml_content;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20001, C_VALIDATION_ERROR);
                it_log.log(v_log_prefix || ' ERROR parsing JSON or missing ReceiptFile: ' || SQLERRM,
                           it_log.C_MSG_TYPE__DEBUG);
                RAISE;
        END ParseReceiptXml;

    /**
     * Определение типа квитанции по структуре XML.
     */
        FUNCTION DetectReceiptType(
            p_xml XMLTYPE,
            p_trace_id_input VARCHAR2
        ) RETURN VARCHAR2
            IS
            C_UNKNOWN_FORMAT CONSTANT VARCHAR2(50) := 'Неизвестный формат';

            v_count NUMBER;
        BEGIN

            SELECT COUNT(*) INTO v_count FROM XMLTABLE('/*[local-name()="Envelope"]' PASSING p_xml);
            IF v_count > 0 THEN
                RETURN 'SOAP';
            END IF;

            SELECT COUNT(*) INTO v_count FROM XMLTABLE('/*[local-name()="Status"]' PASSING p_xml);
            IF v_count > 0 THEN
                RETURN 'STATUS';
            END IF;

            SELECT COUNT(*) INTO v_count FROM XMLTABLE('/*[local-name()="ИЭС1"]' PASSING p_xml);
            IF v_count > 0 THEN
                RETURN 'IES1';
            END IF;

            SELECT COUNT(*) INTO v_count FROM XMLTABLE('/*[local-name()="ИЭС2"]' PASSING p_xml);
            IF v_count > 0 THEN
                RETURN 'IES2';
            END IF;
            RAISE_APPLICATION_ERROR(-20001, C_UNKNOWN_FORMAT);
            RETURN NULL;
        END DetectReceiptType;

    /**
     * Формирование ответа в требуемом формате из данных строки таблицы.
     */
        FUNCTION BuildReceiptJson(
            p_form_code VARCHAR2,
            p_limit_date DATE,
            p_send_day DATE,
            p_reg_day DATE,
            p_status VARCHAR2,
            p_message CLOB
        ) RETURN CLOB
            IS
            v_json_clob CLOB;
        BEGIN
            SELECT JSON_OBJECT(
                           'report_form' VALUE p_form_code,
                           'lim_date' VALUE
                           CASE WHEN p_limit_date IS NOT NULL THEN TO_CHAR(p_limit_date, 'DD.MM.YYYY') ELSE '' END,
                           'send_day' VALUE
                           CASE WHEN p_send_day IS NOT NULL THEN TO_CHAR(p_send_day, 'DD.MM.YYYY') ELSE '' END,
                           'reg_day' VALUE
                           CASE WHEN p_reg_day IS NOT NULL THEN TO_CHAR(p_reg_day, 'DD.MM.YYYY') ELSE '' END,
                           'status' VALUE p_status,
                           'mess' VALUE TO_CLOB(NVL(p_message, '')),
                           'date' VALUE '',
                           'date_end' VALUE ''
                           RETURNING CLOB
                   )
            INTO v_json_clob
            FROM dual;
            RETURN v_json_clob;
        END BuildReceiptJson;

    /**
     * Обработка квитанции типа ИЭС1.
     */
        PROCEDURE ProcessIes1Receipt(
            p_xml XMLTYPE,
            p_trace_id_input VARCHAR2,
            p_result_array IN OUT NOCOPY JSON_ARRAY_T
        )
            IS
            v_form_code      VARCHAR2(20);
            v_send_time_str  VARCHAR2(32);
            v_reg_time_str   VARCHAR2(32);
            v_limit_time_str VARCHAR2(32);
            v_message_detail CLOB;
            v_send_time      TIMESTAMP;
            v_reg_time       TIMESTAMP;
            v_limit_time     TIMESTAMP;
            v_limit_date_db  DATE;
            v_existing_count NUMBER        := 0;
            v_status         VARCHAR2(512);
            v_log_prefix     VARCHAR2(256) := 'traceId=''' || p_trace_id_input || '''';
        BEGIN
            it_log.log(v_log_prefix || ' Processing ИЭС1...', it_log.C_MSG_TYPE__DEBUG);

            SELECT x.form_code,
                   x.send_time,
                   x.reg_time,
                   x.limit_time,
                   x.result_control,
                   x.message_detail
            INTO
                v_form_code, v_send_time_str, v_reg_time_str, v_limit_time_str, v_status, v_message_detail
            FROM XMLTABLE(
                         '/*[local-name()="ИЭС1"]'
                         PASSING p_xml
                         COLUMNS
                             form_code VARCHAR2(20) PATH '*[local-name()="РеквОЭС"]/@КодФормы',
                             send_time VARCHAR2(32) PATH '*[local-name()="РеквОЭС"]/@ДатаВремяФормирования',
                             reg_time VARCHAR2(32) PATH '*[local-name()="РеквОЭС"]/@ДатаВремяРегистрации',
                             limit_time VARCHAR2(32) PATH './@ДатаВремяКонтроля',
                             result_control VARCHAR2(512) PATH './@РезКонтроля',
                             message_detail CLOB PATH '*[local-name()="ПротоколКонтроля"]/*[local-name()="Сообщение"]/text()'
                 ) x;

            it_log.log(
                    v_log_prefix || ' ИЭС1: КодФормы=''' || v_form_code || ''', ДатаВремяКонтроля=''' || v_limit_time_str ||
                    '''', it_log.C_MSG_TYPE__DEBUG);

            IF v_send_time_str IS NOT NULL THEN
                v_send_time := TO_TIMESTAMP_TZ(v_send_time_str, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM');
            END IF;
            IF v_reg_time_str IS NOT NULL THEN
                v_reg_time := TO_TIMESTAMP_TZ(v_reg_time_str, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM');
            END IF;
            IF v_limit_time_str IS NOT NULL THEN
                v_limit_time := TO_TIMESTAMP_TZ(v_limit_time_str, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM');
            END IF;

            v_limit_date_db := TRUNC(v_limit_time);
            it_log.log(v_log_prefix || ' ИЭС1: v_limit_date_db = ' || TO_CHAR(v_limit_date_db, 'YYYY-MM-DD'),
                       it_log.C_MSG_TYPE__DEBUG);

            SELECT COUNT(*)
            INTO v_existing_count
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
                    T_STATUS  = v_status,
                    T_MESSAGE = v_message_detail
                WHERE T_FORM = v_form_code
                  AND T_LIMITDATE = v_limit_date_db
                  AND T_STATUS IS NULL
                  AND (T_MESSAGE IS NULL OR DBMS_LOB.GETLENGTH(T_MESSAGE) = 0);
                it_log.log(v_log_prefix || ' ИЭС1: UPDATED existing stub record (form=' || v_form_code || ', limit_date=' ||
                           TO_CHAR(v_limit_date_db, 'YYYY-MM-DD') || ')', it_log.C_MSG_TYPE__DEBUG);
            ELSE
                BEGIN
                    INSERT INTO DBDUI_REPORTPOSTINFO_DBT (T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE,
                                                          T_ADDTIME)
                    VALUES (v_form_code,
                            v_limit_date_db,
                            CAST(v_send_time AS DATE),
                            CAST(v_reg_time AS DATE),
                            v_status,
                            v_message_detail,
                            SYSTIMESTAMP);
                    it_log.log(v_log_prefix || ' ИЭС1: INSERTED new record (form=' || v_form_code || ', limit_date=' ||
                               TO_CHAR(v_limit_date_db, 'YYYY-MM-DD') || ')', it_log.C_MSG_TYPE__DEBUG);
                EXCEPTION
                    WHEN DUP_VAL_ON_INDEX THEN
                        it_log.log(v_log_prefix || ' ERROR: Unique constraint violated - квитанция уже загружена',
                                   it_log.C_MSG_TYPE__DEBUG);
                        RAISE;
                END;
            END IF;

            DECLARE
                v_json_clob CLOB;
            BEGIN
                v_json_clob :=
                        BuildReceiptJson(v_form_code, v_limit_date_db, v_send_time, v_reg_time, v_status, v_message_detail);
                p_result_array.append(JSON_OBJECT_T.parse(v_json_clob));
                it_log.log(v_log_prefix || ' ИЭС1: JSON output generated successfully', it_log.C_MSG_TYPE__DEBUG);
            END;
        END ProcessIes1Receipt;

    /**
     * Обработка квитанции типа ИЭС2.
     */
        PROCEDURE ProcessIes2Receipt(
            p_xml XMLTYPE,
            p_trace_id_input VARCHAR2,
            p_result_array IN OUT NOCOPY JSON_ARRAY_T
        )
            IS
            v_form_code      VARCHAR2(20);
            v_send_time_str  VARCHAR2(32);
            v_reg_time_str   VARCHAR2(32);
            v_limit_time_str VARCHAR2(32);
            v_message_detail CLOB;
            v_send_time      TIMESTAMP;
            v_reg_time       TIMESTAMP;
            v_limit_time     TIMESTAMP;
            v_limit_date_db  DATE;
            v_existing_count NUMBER        := 0;
            v_status         VARCHAR2(512);
            v_log_prefix     VARCHAR2(256) := 'AddReceiptInfoReport AddReceiptInfo_RC_ReportRun traceId=''' ||
                                              COALESCE(p_trace_id_input, 'NULL') || '''';
        BEGIN
            it_log.log(v_log_prefix || ' Processing ИЭС2...', it_log.C_MSG_TYPE__DEBUG);

            SELECT r.form_code,
                   r.send_time,
                   r.reg_time,
                   r.limit_time,
                   r.result_control,
                   LISTAGG(m.msg, CHR(10)) WITHIN GROUP (ORDER BY m.msg)
            INTO
                v_form_code, v_send_time_str, v_reg_time_str, v_limit_time_str, v_status, v_message_detail
            FROM XMLTABLE(
                         '/*[local-name()="ИЭС2"]'
                         PASSING p_xml
                         COLUMNS
                             form_code VARCHAR2(20) PATH '*[local-name()="РеквОЭС"]/@КодФормы',
                             send_time VARCHAR2(32) PATH '*[local-name()="РеквОЭС"]/@ДатаВремяФормирования',
                             reg_time VARCHAR2(32) PATH '*[local-name()="РеквОЭС"]/@ДатаВремяРегистрации',
                             limit_time VARCHAR2(32) PATH '*[local-name()="ДанныеОЭС"]/@ДатаВремяКонтроля',
                             result_control VARCHAR2(512) PATH '*[local-name()="ДанныеОЭС"]/@РезКонтроля'
                 ) r
                     CROSS JOIN XMLTABLE(
                    '/*[local-name()="ИЭС2"]/*[local-name()="ДанныеОЭС"]/*[local-name()="ПротоколКонтроля"]/*[local-name()="Сообщение"]'
                    PASSING p_xml
                    COLUMNS
                        msg VARCHAR2(4000) PATH '.'
                                ) m
            GROUP BY r.form_code, r.send_time, r.reg_time, r.limit_time, r.result_control;

            it_log.log(
                    v_log_prefix || ' ИЭС2: КодФормы=''' || v_form_code || ''', ДатаВремяКонтроля=''' || v_limit_time_str ||
                    '''', it_log.C_MSG_TYPE__DEBUG);
            it_log.log(v_log_prefix || ' ИЭС2: сообщений найдено = ' || CASE
                                                                            WHEN v_message_detail IS NOT NULL THEN
                                                                                LENGTH(v_message_detail) -
                                                                                LENGTH(REPLACE(v_message_detail, CHR(10), '')) +
                                                                                1
                                                                            ELSE 0 END, it_log.C_MSG_TYPE__DEBUG);

            IF v_send_time_str IS NOT NULL THEN
                v_send_time := TO_TIMESTAMP_TZ(v_send_time_str, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM');
            END IF;
            IF v_reg_time_str IS NOT NULL THEN
                v_reg_time := TO_TIMESTAMP_TZ(v_reg_time_str, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM');
            END IF;
            IF v_limit_time_str IS NOT NULL THEN
                v_limit_time := TO_TIMESTAMP_TZ(v_limit_time_str, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM');
            END IF;

            v_limit_date_db := TRUNC(v_limit_time);
            it_log.log(v_log_prefix || ' ИЭС2: v_limit_date_db = ' || TO_CHAR(v_limit_date_db, 'YYYY-MM-DD'),
                       it_log.C_MSG_TYPE__DEBUG);

            SELECT COUNT(*)
            INTO v_existing_count
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
                    T_STATUS  = v_status,
                    T_MESSAGE = v_message_detail
                WHERE T_FORM = v_form_code
                  AND T_LIMITDATE = v_limit_date_db
                  AND T_STATUS IS NULL
                  AND (T_MESSAGE IS NULL OR DBMS_LOB.GETLENGTH(T_MESSAGE) = 0);
                it_log.log(v_log_prefix || ' ИЭС2: UPDATED existing stub record (form=' || v_form_code || ', limit_date=' ||
                           TO_CHAR(v_limit_date_db, 'YYYY-MM-DD') || ')', it_log.C_MSG_TYPE__DEBUG);
            ELSE
                BEGIN
                    INSERT INTO DBDUI_REPORTPOSTINFO_DBT (T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE,
                                                          T_ADDTIME)
                    VALUES (v_form_code,
                            v_limit_date_db,
                            CAST(v_send_time AS DATE),
                            CAST(v_reg_time AS DATE),
                            v_status,
                            v_message_detail,
                            SYSTIMESTAMP);
                    it_log.log(v_log_prefix || ' ИЭС2: INSERTED new record (form=' || v_form_code || ', limit_date=' ||
                               TO_CHAR(v_limit_date_db, 'YYYY-MM-DD') || ')', it_log.C_MSG_TYPE__DEBUG);
                EXCEPTION
                    WHEN DUP_VAL_ON_INDEX THEN
                        it_log.log(v_log_prefix || ' ERROR: Unique constraint violated - квитанция уже загружена',
                                   it_log.C_MSG_TYPE__DEBUG);
                        RAISE;
                END;
            END IF;

            DECLARE
                v_json_clob CLOB;
            BEGIN
                v_json_clob :=
                        BuildReceiptJson(v_form_code, v_limit_date_db, v_send_time, v_reg_time, v_status, v_message_detail);
                p_result_array.append(JSON_OBJECT_T.parse(v_json_clob));
                it_log.log(v_log_prefix || ' ИЭС2: JSON output generated successfully', it_log.C_MSG_TYPE__DEBUG);
            END;
        END ProcessIes2Receipt;

    /**
     * Обработка квитанции типа Status.
     */
        PROCEDURE ProcessStatusReceipt(
            p_xml XMLTYPE,
            p_trace_id_input VARCHAR2,
            p_result_array IN OUT NOCOPY JSON_ARRAY_T
        )
            IS
            v_rowid       ROWID;
            v_form_code   VARCHAR2(20);
            v_limit_date  DATE;
            v_send_day    DATE;
            v_reg_day     DATE;
            v_message     CLOB;
            v_limit_calc  DATE;
            v_status      VARCHAR2(512);
            v_date_time   TIMESTAMP;
            v_reg_num     VARCHAR2(64);
            v_result_text VARCHAR2(64);
            v_log_prefix  VARCHAR2(256) := 'AddReceiptInfoReport AddReceiptInfo_RC_ReportRun traceId=''' ||
                                           COALESCE(p_trace_id_input, 'NULL') || '''';
        BEGIN
            it_log.log(v_log_prefix || ' Processing Status receipt...', it_log.C_MSG_TYPE__DEBUG);

            SELECT x.regNum, x.status, TO_TIMESTAMP_TZ(x.dateTime, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM')
            INTO v_reg_num, v_result_text, v_date_time
            FROM XMLTABLE(
                         XMLNAMESPACES ('http://www.cbr.ru/igr/' AS "igr"),
                         '/igr:Status' PASSING p_xml
                         COLUMNS regNum VARCHAR2(64) PATH 'igr:regNum', status VARCHAR2(64) PATH 'igr:status', dateTime VARCHAR2(32) PATH 'igr:dateTime'
                 ) x;

            v_status := CASE LOWER(v_result_text)
                            WHEN 'delivered' THEN 'загружено'
                            WHEN 'registered' THEN 'зарегистрировано'
                            WHEN 'processing' THEN 'принято в обработку'
                            ELSE v_result_text
                END;

            v_limit_calc := TRUNC(v_date_time);
            it_log.log(
                    v_log_prefix || ' Status: dateTime=' || TO_CHAR(v_date_time, 'YYYY-MM-DD HH24:MI:SS') ||
                    ', T_LIMITDATE=' ||
                    TO_CHAR(v_limit_calc, 'YYYY-MM-DD'), it_log.C_MSG_TYPE__DEBUG);

            UPDATE DBDUI_REPORTPOSTINFO_DBT
            SET T_REGDATE = CAST(v_date_time AS DATE),
                T_STATUS  = v_status
            WHERE T_FORM = 'admission_procedure'
              AND T_LIMITDATE = v_limit_calc
              AND T_STATUS IS NULL
            RETURNING ROWID INTO v_rowid;

            IF SQL%ROWCOUNT > 0 THEN
                it_log.log(v_log_prefix || ' Updated existing Status record (T_STATUS was NULL)', it_log.C_MSG_TYPE__DEBUG);
                SELECT T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE
                INTO v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message
                FROM DBDUI_REPORTPOSTINFO_DBT
                WHERE ROWID = v_rowid;
            ELSE
                BEGIN
                    INSERT INTO DBDUI_REPORTPOSTINFO_DBT (T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE,
                                                          T_ADDTIME)
                    VALUES ('admission_procedure',
                            v_limit_calc,
                            NULL,
                            CAST(v_date_time AS DATE),
                            v_status,
                            NULL,
                            SYSTIMESTAMP)
                    RETURNING ROWID INTO v_rowid;
                    it_log.log(v_log_prefix || ' INSERTED new Status record', it_log.C_MSG_TYPE__DEBUG);
                    SELECT T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE
                    INTO v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message
                    FROM DBDUI_REPORTPOSTINFO_DBT
                    WHERE ROWID = v_rowid;
                EXCEPTION
                    WHEN DUP_VAL_ON_INDEX THEN
                        it_log.log(v_log_prefix || ' ERROR: Unique constraint violated - квитанция уже загружена',
                                   it_log.C_MSG_TYPE__DEBUG);
                        RAISE;
                END;
            END IF;

            DECLARE
                v_json_clob CLOB;
            BEGIN
                v_json_clob := BuildReceiptJson(v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message);
                p_result_array.append(JSON_OBJECT_T.parse(v_json_clob));
                it_log.log(v_log_prefix || ' Status: JSON output generated successfully', it_log.C_MSG_TYPE__DEBUG);
            END;
        END ProcessStatusReceipt;

    /**
     * Обработка квитанции типа SOAP.
     */
        PROCEDURE ProcessSoapReceipt(
            p_xml XMLTYPE,
            p_trace_id_input VARCHAR2,
            p_result_array IN OUT NOCOPY JSON_ARRAY_T
        )
            IS
            v_rowid          ROWID;
            v_form_code      VARCHAR2(20);
            v_limit_date     DATE;
            v_send_day       DATE;
            v_reg_day        DATE;
            v_message        CLOB;
            v_limit_calc     DATE;
            v_status         VARCHAR2(512);
            v_create_time    TIMESTAMP;
            v_correlation_id VARCHAR2(64);
            v_result_text    VARCHAR2(64);
            v_log_prefix     VARCHAR2(256) := 'AddReceiptInfoReport AddReceiptInfo_RC_ReportRun traceId=''' ||
                                              COALESCE(p_trace_id_input, 'NULL') || '''';
        BEGIN
            it_log.log(v_log_prefix || ' Processing SOAP receipt...', it_log.C_MSG_TYPE__DEBUG);

            SELECT x.CorrelationMessageID, a.ResultText, TO_TIMESTAMP_TZ(x.CreateTime, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM')
            INTO v_correlation_id, v_result_text, v_create_time
            FROM XMLTABLE(
                         XMLNAMESPACES ('http://www.w3.org/2003/05/soap-envelope' AS "env", 'urn:cbr-ru:msg:props:v1.3' AS "props"),
                         '/env:Envelope/env:Header/props:MessageInfo' PASSING p_xml
                         COLUMNS CorrelationMessageID VARCHAR2(64) PATH 'props:CorrelationMessageID',
                             CreateTime VARCHAR2(32) PATH 'props:CreateTime'
                 ) x
                     CROSS JOIN XMLTABLE(
                    XMLNAMESPACES ('urn:cbr-ru:msg:props:v1.3' AS "props"),
                    '/props:AcknowledgementInfo' PASSING p_xml
                    COLUMNS ResultText VARCHAR2(64) PATH 'props:ResultText'
                                ) a;

            v_status := CASE LOWER(v_result_text)
                            WHEN 'delivered' THEN 'загружено'
                            WHEN 'registered' THEN 'зарегистрировано'
                            WHEN 'processing' THEN 'принято в обработку'
                            ELSE v_result_text
                END;

            v_limit_calc := TRUNC(v_create_time);
            it_log.log(v_log_prefix || ' SOAP: CreateTime=' || TO_CHAR(v_create_time, 'YYYY-MM-DD HH24:MI:SS') ||
                       ', T_LIMITDATE=' || TO_CHAR(v_limit_calc, 'YYYY-MM-DD'), it_log.C_MSG_TYPE__DEBUG);

            UPDATE DBDUI_REPORTPOSTINFO_DBT
            SET T_SENDDAY = CAST(v_create_time AS DATE),
                T_STATUS  = v_status
            WHERE T_FORM = 'admission_procedure'
              AND T_LIMITDATE = v_limit_calc
              AND T_STATUS IS NULL
            RETURNING ROWID INTO v_rowid;

            IF SQL%ROWCOUNT > 0 THEN
                it_log.log(v_log_prefix || ' Updated existing SOAP record (T_STATUS was NULL)', it_log.C_MSG_TYPE__DEBUG);
                SELECT T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE
                INTO v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message
                FROM DBDUI_REPORTPOSTINFO_DBT
                WHERE ROWID = v_rowid;
            ELSE
                BEGIN
                    INSERT INTO DBDUI_REPORTPOSTINFO_DBT (T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE,
                                                          T_ADDTIME)
                    VALUES ('admission_procedure',
                            v_limit_calc,
                            CAST(v_create_time AS DATE),
                            NULL,
                            v_status,
                            NULL,
                            SYSTIMESTAMP)
                    RETURNING ROWID INTO v_rowid;
                    it_log.log(v_log_prefix || ' INSERTED new SOAP record', it_log.C_MSG_TYPE__DEBUG);
                    SELECT T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE
                    INTO v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message
                    FROM DBDUI_REPORTPOSTINFO_DBT
                    WHERE ROWID = v_rowid;
                EXCEPTION
                    WHEN DUP_VAL_ON_INDEX THEN
                        it_log.log(v_log_prefix || ' ERROR: Unique constraint violated - квитанция уже загружена',
                                   it_log.C_MSG_TYPE__DEBUG);
                        RAISE;
                END;
            END IF;

            DECLARE
                v_json_clob CLOB;
            BEGIN
                v_json_clob := BuildReceiptJson(v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message);
                p_result_array.append(JSON_OBJECT_T.parse(v_json_clob));
                it_log.log(v_log_prefix || ' SOAP: JSON output generated successfully', it_log.C_MSG_TYPE__DEBUG);
            END;
        END ProcessSoapReceipt;

    -- === ОСНОВНАЯ ФУНКЦИЯ ===

        FUNCTION AddReceiptInfo_RC_ReportRun(
            p_trace_id_input VARCHAR2,
            p_json_input CLOB,
            p_is_production CHAR DEFAULT '1'
        ) RETURN CLOB
            IS
            PRAGMA AUTONOMOUS_TRANSACTION;
            C_TEMPLATE_NAME CONSTANT        VARCHAR2(128) := 'limit_day_report';
            C_S3_FILE_NAME CONSTANT         VARCHAR2(128) := 'control_dates_report_';
            C_REPORT_NAME_TAG CONSTANT      VARCHAR2(128) := 'GetLmitDayReport';
            C_ITEMS_ARR_TAG CONSTANT        VARCHAR2(128) := 'LimitDay_info';
            C_OUTPUT_FILE_NAME_PRE CONSTANT VARCHAR2(128) := 'Квитанции_БР';
            C_ERR_99_CODE CONSTANT          VARCHAR2(8)   := 'ER_99';
            C_ERR_99_MSG CONSTANT           VARCHAR2(64)  := 'СОФР не смог обработать квитанцию: ошибка';
            C_EMPTY_JSON_ARRAY CONSTANT     CLOB          := TO_CLOB('[]');
            C_ERR_UNIQUE_CODE CONSTANT      VARCHAR2(8)   := 'ER_01';
            v_xml_content                   CLOB;
            v_xml                           XMLTYPE;
            v_result_array                  JSON_ARRAY_T  := JSON_ARRAY_T();
            v_json_output                   CLOB;
            v_errors_array                  JSON_ARRAY_T  := JSON_ARRAY_T();
            v_log_prefix                    VARCHAR2(256) :=
                'AddReceiptInfoReport AddReceiptInfo_RC_ReportRun traceId=''' || COALESCE(p_trace_id_input, 'NULL') || '''';
            v_receipt_type                  VARCHAR2(10);
        BEGIN
            it_log.log(v_log_prefix || ' Input p_json_input (first 2000 chars): ' || DBMS_LOB.SUBSTR(p_json_input, 2000, 1),
                       it_log.C_MSG_TYPE__DEBUG);
            it_log.log(v_log_prefix || ' >>> FUNCTION STARTED <<<', it_log.C_MSG_TYPE__DEBUG);

            -- Обработка пустого входа
            IF p_json_input IS NULL OR p_json_input = '{}' OR p_json_input = '[]' THEN
                it_log.log(v_log_prefix || ' Empty or trivial input, returning Meta UI', it_log.C_MSG_TYPE__DEBUG);
                v_json_output := BuildJsonOutput(p_body => AddReceiptInfoReportMetaUi());
                it_log.log(v_log_prefix || ' Returning (empty input): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1),
                           it_log.C_MSG_TYPE__DEBUG);
                RETURN v_json_output;
            END IF;

            -- Парсинг и валидация входного XML
            BEGIN
                v_xml_content := ParseReceiptXml( p_trace_id_input);
                v_xml := XMLTYPE(v_xml_content);
                it_log.log(v_log_prefix || ' XML parsed successfully', it_log.C_MSG_TYPE__DEBUG);
            EXCEPTION
                WHEN OTHERS THEN
                    it_log.log(v_log_prefix || ' ERROR parsing XML: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
                    v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, 'Некорректный XML'));
                    v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                    it_log.log(v_log_prefix || ' Returning (XML parse error): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1),
                               it_log.C_MSG_TYPE__DEBUG);
                    RETURN v_json_output;
            END;

            -- Определение типа квитанции
            v_receipt_type := DetectReceiptType(v_xml, p_trace_id_input);
            IF v_receipt_type IS NULL THEN
                v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, 'Неизвестный формат квитанции'));
                v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                it_log.log(v_log_prefix || ' Returning (unknown XML): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1),
                           it_log.C_MSG_TYPE__DEBUG);
                RETURN v_json_output;
            END IF;

            -- Обработка по типу
            BEGIN
                CASE v_receipt_type
                    WHEN 'SOAP' THEN ProcessSoapReceipt(v_xml, p_trace_id_input, v_result_array);
                    WHEN 'STATUS' THEN ProcessStatusReceipt(v_xml, p_trace_id_input, v_result_array);
                    WHEN 'IES1' THEN ProcessIes1Receipt(v_xml, p_trace_id_input, v_result_array);
                    WHEN 'IES2' THEN ProcessIes2Receipt(v_xml, p_trace_id_input, v_result_array);
                    END CASE;
            EXCEPTION
                WHEN DUP_VAL_ON_INDEX THEN
                    it_log.log(v_log_prefix || ' ERROR: Unique constraint violated - квитанция уже загружена',
                               it_log.C_MSG_TYPE__DEBUG);
                    v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_UNIQUE_CODE,
                                                            'данная квитанция уже загружалась'));
                    v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                    it_log.log(v_log_prefix || ' Returning (duplicate): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1),
                               it_log.C_MSG_TYPE__DEBUG);
                    RETURN v_json_output;
                WHEN OTHERS THEN
                    it_log.log(v_log_prefix || ' ERROR during receipt processing: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
                    v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                            'Ошибка при обработке квитанции: ' || SQLERRM));
                    v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                    it_log.log(v_log_prefix || ' Returning (processing error): ' || DBMS_LOB.SUBSTR(v_json_output, 2000, 1),
                               it_log.C_MSG_TYPE__DEBUG);
                    RETURN v_json_output;
            END;

            COMMIT;
            it_log.log(v_log_prefix || ' Transaction committed', it_log.C_MSG_TYPE__DEBUG);

            -- Формирование финального результата
            v_json_output := v_result_array.to_clob();
            v_json_output := BuildSplitJsonOutput(
                    p_trace_id_input => p_trace_id_input, p_json_input => v_json_output, p_report_date_input => SYSDATE,
                    p_report_tag => C_REPORT_NAME_TAG, p_items_arr_tag => C_ITEMS_ARR_TAG,
                    p_template_name => C_TEMPLATE_NAME,
                    p_output_file_name => C_OUTPUT_FILE_NAME_PRE, p_s3_file_name => C_S3_FILE_NAME
                             );

            it_log.log(v_log_prefix || ' Final output (first 2000 chars): ' ||
                       DBMS_LOB.SUBSTR(COALESCE(v_json_output, TO_CLOB('NULL')), 2000, 1), it_log.C_MSG_TYPE__DEBUG);
            it_log.log(v_log_prefix || ' <<< FUNCTION COMPLETED SUCCESSFULLY >>>', it_log.C_MSG_TYPE__DEBUG);
            RETURN v_json_output;

        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                ROLLBACK;
                it_log.log(v_log_prefix || ' FATAL ERROR: Unique constraint violated - квитанция уже загружена',
                           it_log.C_MSG_TYPE__DEBUG);
                v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_UNIQUE_CODE,
                                                        'данная квитанция уже загружалась'));
                v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                it_log.log(v_log_prefix || ' Returning (duplicate exception): ' ||
                           DBMS_LOB.SUBSTR(COALESCE(v_json_output, TO_CLOB('NULL')), 2000, 1), it_log.C_MSG_TYPE__DEBUG);
                RETURN v_json_output;
            WHEN OTHERS THEN
                ROLLBACK;
                it_log.log(v_log_prefix || ' FATAL ERROR in function: ' || SQLERRM, it_log.C_MSG_TYPE__DEBUG);
                it_error.put_error_in_stack;
                v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, C_ERR_99_MSG || ': ' || SQLERRM));
                v_json_output := BuildJsonOutput(p_errors_array => v_errors_array);
                it_log.log(v_log_prefix || ' Returning (exception): ' ||
                           DBMS_LOB.SUBSTR(COALESCE(v_json_output, TO_CLOB('NULL')), 2000, 1), it_log.C_MSG_TYPE__DEBUG);
                RETURN v_json_output;
        END AddReceiptInfo_RC_ReportRun;


END IT_CheckLimitReport;