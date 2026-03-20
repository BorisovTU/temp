CREATE OR REPLACE PACKAGE BODY IT_CheckLimitReport AS
  /**************************************************************************************************\
  Пакет для генерации отчётов: BIQ-23781(intech), BIQ-29457(avt) РМ контролера - Внедрение автоматизированного внутреннего контроля операций на финансовых рынках, их учета и формирования отчетности в ИС СОФР
  **************************************************************************************************
  Изменения:
  --------------------------------------------------------------------------------------------------------------
  Дата        Автор            Jira                                    Описание
  ----------  ---------------  --------------------------------------  -----------------------------------------
  06.08.2025  Логинов Н.А.     BIQ-23781(intech), BIQ-29457(avt)     Создание
  \*************************************************************************************************************/

  --------------------------------------------------------------------------------------------------------------------
  ----- Константы - Структура выходного JSON, общие для всего пакета -----
  --------------------------------------------------------------------------------------------------------------------
  C_OUTPUT_TAG__HEADERS          CONSTANT VARCHAR2(7)  := 'headers';
  C_OUTPUT_TAG__BODY             CONSTANT VARCHAR2(4)  := 'body';
  C_OUTPUT_TAG__ERRORS           CONSTANT VARCHAR2(6)  := 'errors';
  C_OUTPUT_TAG__EXMETA           CONSTANT VARCHAR2(6)  := 'exMeta';

  --------------------------------------------------------------------------------------------------------------------
  ----- Константы - Структура MetaUI, общие для всего пакета -----
  --------------------------------------------------------------------------------------------------------------------
  C_META_UI_TAG__ROLES           CONSTANT VARCHAR2(5)  := 'roles';
  C_META_UI_TAG__LABEL           CONSTANT VARCHAR2(5)  := 'label';
  C_META_UI_TAG__SYSTAGS         CONSTANT VARCHAR2(7)  := 'sysTags';
  C_META_UI_TAG__FORM            CONSTANT VARCHAR2(7)  := 'form';

  --------------------------------------------------------------------------------------------------------------------
  ----- Константы - Общего назначения, общие для всего пакета -----
  --------------------------------------------------------------------------------------------------------------------
  -- Ограничение Фабрики документов 30МБ на запрос, поэтому ограничим размер одной части 29МБ, 1МБ резерв на разделители, символы экранирования (при наличии спец символов в полях json), header'ы сообщения и т.д.
  C_MAX_DATA_SIZE_PER_PART       CONSTANT INTEGER      := 29 * 1024 * 1024; -- Максимальный размер данных для одной части отчёта (в байтах)

  --------------------------------------------------
  ----- Константы - Биржевые файлы, общие для сверок СОФР-Биржа -----
  --------------------------------------------------
  C_MARKET_FILE_TAG__STOCKS      CONSTANT VARCHAR2(17) := 'marketFilesStocks';
  C_MARKET_FILE_JPATH__STOCKS    CONSTANT VARCHAR2(25) := '$.marketFilesStocks.files';
  C_MARKET_FILE_TAG__FOREX       CONSTANT VARCHAR2(16) := 'marketFilesForex';
  C_MARKET_FILE_JPATH__FOREX     CONSTANT VARCHAR2(24) := '$.marketFilesForex.files';
  C_MARKET_FILE_TAG__FUTURES     CONSTANT VARCHAR2(18) := 'marketFilesFutures';
  C_MARKET_FILE_JPATH__FUTURES   CONSTANT VARCHAR2(26) := '$.marketFilesFutures.files';
  C_MARKET_FILE_TAG__OPTIONS     CONSTANT VARCHAR2(18) := 'marketFilesOptions';
  C_MARKET_FILE_JPATH__OPTIONS   CONSTANT VARCHAR2(26) := '$.marketFilesOptions.files';
  -- Объект биржевых файлов
  C_MARKET_FILE_TAG__ERROR       CONSTANT VARCHAR2(18) := 'error';
  C_MARKET_FILE_TAG__SEARCH_PATH CONSTANT VARCHAR2(18) := 'searchPath';
  C_MARKET_FILE_TAG__SHARE_PATH  CONSTANT VARCHAR2(18) := 'sharePath';

  -- CAMEL SCRIPTS
  C_STOCKS_M_CAMEL_ROUTEID       CONSTANT VARCHAR2(36) := '30a321c3-0019-41c1-918b-c5a146da53d3';
  C_STOCKS_M_CAMEL_SCRIPT        CONSTANT CLOB := '<route id="30a321c3-0019-41c1-918b-c5a146da53d3" xmlns="http://camel.apache.org/schema/spring"> <from uri="direct:30a321c3-0019-41c1-918b-c5a146da53d3"/> <setProperty name="originalBody"> <simple>${body}</simple> </setProperty> <unmarshal> <json library="Jackson"/> </unmarshal> <setHeader name="Content-Type"> <constant>application/json</constant> </setHeader> <setProperty name="date"> <groovy> def inFmt = java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"); def outFmt = java.time.format.DateTimeFormatter.ofPattern("ddMMyy"); return java.time.LocalDate.parse(request.body.reportDate, inFmt).format(outFmt); </groovy> </setProperty> <setBody> <simple> { "searchList": [ { "folder": "moex", "identity": "marketFilesStocks", "fileMask": ".*MC01347_SEM03_.*_${exchangeProperty.date}_.*" } ] } </simple> </setBody> <toD uri="{{APP_FILE_SHARE_SERVICE_URL}}?throwExceptionOnFailure=false"/> <setProperty name="httpStatus"> <simple>${header.CamelHttpResponseCode}</simple> </setProperty> <choice> <when> <simple>${exchangeProperty.httpStatus} == 400</simple> <setBody> <simple> { "errorCode": "ER_02", "errorMessage": "СОФР не смог сформировать отчет: на указанную дату нет биржевого файла ${jq(".fileName | map(tostring) | join("&lt;br&gt;")")}" } </simple> </setBody> <transform> <jq>{ "errorDto": . }</jq> </transform> <stop/> </when> </choice> <transform> <jq><![CDATA[ .files | group_by(.fileIdentity) | map( { key: .[0].fileIdentity, value: ( (if any(.[]; .isError) then { error: { sharePath: .[].sharePath } + ( [ .[] | select(.isError) | (.fileName) | select(. != null) ] | if length > 0 then { searchPath: (join("&lt;br&gt;")) } else {} end ) } else { files: [ .[] | .fileData | select(. != null) ] } end) ) } ) | from_entries ]]></jq> </transform> <setBody> <simple> ${jq("(property("originalBody") | fromjson) + .")} </simple> </setBody> <transform> <jq>{ "response": ( . | tostring ) }</jq> </transform></route>';
  C_FOREX_M_CAMEL_ROUTEID        CONSTANT VARCHAR2(36) := '58ad3ae2-390d-42d7-b7f6-d311c02c476a';
  C_FOREX_M_CAMEL_SCRIPT         CONSTANT CLOB := '<route id="58ad3ae2-390d-42d7-b7f6-d311c02c476a" xmlns="http://camel.apache.org/schema/spring"> <from uri="direct:58ad3ae2-390d-42d7-b7f6-d311c02c476a"/> <setProperty name="originalBody"> <simple>${body}</simple> </setProperty> <unmarshal> <json library="Jackson"/> </unmarshal> <setHeader name="Content-Type"> <constant>application/json</constant> </setHeader>  <setProperty name="date"> <groovy> def inFmt = java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"); def outFmt = java.time.format.DateTimeFormatter.ofPattern("ddMMyy"); return java.time.LocalDate.parse(request.body.reportDate, inFmt).format(outFmt); </groovy> </setProperty> <setBody> <simple> { "searchList": [ { "folder": "moex", "identity": "marketFilesForex", "fileMask": ".*MB01347_CUX23_.*_${exchangeProperty.date}_.*" } ] } </simple> </setBody> <toD uri="{{APP_FILE_SHARE_SERVICE_URL}}?throwExceptionOnFailure=false"/> <setProperty name="httpStatus"> <simple>${header.CamelHttpResponseCode}</simple> </setProperty> <choice> <when> <simple>${exchangeProperty.httpStatus} == 400</simple> <setBody> <simple> { "errorCode": "ER_02", "errorMessage": "СОФР не смог сформировать отчет: на указанную дату нет биржевого файла ${jq(".fileName | map(tostring) | join("&lt;br&gt;")")}" } </simple> </setBody> <transform> <jq>{ "errorDto": . }</jq> </transform> <stop/> </when> </choice> <transform> <jq><![CDATA[ .files | group_by(.fileIdentity) | map( { key: .[0].fileIdentity, value: ( (if any(.[]; .isError) then  { error: {  sharePath: .[].sharePath  } + (  [ .[]  | select(.isError)  | (.fileName)  | select(. != null)  ] | if length > 0 then  { searchPath: (join("&lt;br&gt;")) }  else {}  end  ) }  else { files: [ .[] | .fileData | select(. != null) ] }  end) ) } ) | from_entries ]]></jq> </transform> <setBody> <simple> ${jq("(property("originalBody") | fromjson) + .")} </simple> </setBody> <transform> <jq>{ "response": ( . | tostring ) }</jq> </transform> </route>';
  C_DERIVATIVES_M_CAMEL_ROUTEID  CONSTANT VARCHAR2(36) := '71f7e581-ca6c-4c76-aa5b-c9ef49ee68d9';
  C_DERIVATIVES_M_CAMEL_SCRIPT   CONSTANT CLOB := '<route id="71f7e581-ca6c-4c76-aa5b-c9ef49ee68d9" xmlns="http://camel.apache.org/schema/spring"> <from uri="direct:71f7e581-ca6c-4c76-aa5b-c9ef49ee68d9"/> <setProperty name="originalBody"> <simple>${body}</simple> </setProperty> <unmarshal> <json library="Jackson"/> </unmarshal> <setHeader name="Content-Type"> <constant>application/json</constant> </setHeader><setProperty name="date"> <groovy> def inFmt = java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"); def outFmt = java.time.format.DateTimeFormatter.ofPattern("dd.MM.yy"); return java.time.LocalDate.parse(request.body.reportDate, inFmt).format(outFmt); </groovy> </setProperty> <setBody> <simple> { "searchList": [ { "folder": "FORTSMICEX", "identity": "marketFilesFutures", "fileMask": ".*${exchangeProperty.date}/.*f04_.*.csv" }, { "folder": "FORTSMICEX", "identity": "marketFilesOptions", "fileMask": ".*${exchangeProperty.date}/.*o04_.*.csv" } ] } </simple> </setBody> <toD uri="{{APP_FILE_SHARE_SERVICE_URL}}?throwExceptionOnFailure=false"/> <setProperty name="httpStatus"> <simple>${header.CamelHttpResponseCode}</simple> </setProperty> <choice> <when> <simple>${exchangeProperty.httpStatus} == 400</simple> <setBody> <simple> { "errorCode": "ER_02", "errorMessage": "СОФР не смог сформировать отчет: на указанную дату нет биржевого файла ${jq(".fileName | map(tostring) | join("&lt;br&gt;")")}" } </simple> </setBody> <transform> <jq>{ "errorDto": . }</jq> </transform> <stop/> </when> </choice> <transform> <jq><![CDATA[ .files | group_by(.fileIdentity) | map( { key: .[0].fileIdentity, value: ( (if any(.[]; .isError) then{ error: {sharePath: .[].sharePath} + ([ .[]| select(.isError)| (.fileName)| select(. != null)] | if length > 0 then{ searchPath: (join("&lt;br&gt;")) }else {}end) }else { files: [ .[] | .fileData | select(. != null) ] }end) ) } ) | from_entries ]]></jq> </transform> <setBody> <simple> ${jq("(property("originalBody") | fromjson) + .")} </simple> </setBody> <transform> <jq>{ "response": ( . | tostring ) }</jq> </transform> </route>';
  C_ALL_M_CAMEL_ROUTEID          CONSTANT VARCHAR2(36) := '3e984f3a-c72d-465b-8814-a17fc523b04a';
  C_ALL_M_CAMEL_SCRIPT           CONSTANT CLOB := '<route id="3e984f3a-c72d-465b-8814-a17fc523b04a" xmlns="http://camel.apache.org/schema/spring"> <from uri="direct:3e984f3a-c72d-465b-8814-a17fc523b04a"/> <setProperty name="originalBody"> <simple>${body}</simple> </setProperty> <unmarshal> <json library="Jackson"/> </unmarshal> <setHeader name="Content-Type"> <constant>application/json</constant> </setHeader><setProperty name="date"> <groovy> def inFmt = java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"); def outFmt = java.time.format.DateTimeFormatter.ofPattern("dd.MM.yy"); return java.time.LocalDate.parse(request.body.reportDate, inFmt).format(outFmt); </groovy> </setProperty> <setProperty name="dateMoex"> <groovy> def inFmt = java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd"); def outFmt = java.time.format.DateTimeFormatter.ofPattern("ddMMyy"); return java.time.LocalDate.parse(request.body.reportDate, inFmt).format(outFmt); </groovy> </setProperty> <setBody> <simple> { "searchList": [ { "folder": "FORTSMICEX", "identity": "marketFilesFutures", "fileMask": ".*${exchangeProperty.date}/.*f04_.*.csv" }, { "folder": "FORTSMICEX", "identity": "marketFilesOptions", "fileMask": ".*${exchangeProperty.date}/.*o04_.*.csv" }, { "folder": "moex", "identity": "marketFilesForex", "fileMask": ".*MB01347_CUX23_.*_${exchangeProperty.dateMoex}_.*" }, { "folder": "moex", "identity": "marketFilesStocks", "fileMask": ".*MC01347_SEM03_.*_${exchangeProperty.dateMoex}_.*" } ] } </simple> </setBody> <toD uri="{{APP_FILE_SHARE_SERVICE_URL}}?throwExceptionOnFailure=false"/> <setProperty name="httpStatus"> <simple>${header.CamelHttpResponseCode}</simple> </setProperty> <choice> <when> <simple>${exchangeProperty.httpStatus} == 400</simple> <setBody> <simple> { "errorCode": "ER_02", "errorMessage": "СОФР не смог сформировать отчет: на указанную дату нет биржевого файла ${jq(".fileName | map(tostring) | join("&lt;br&gt;")")}" } </simple> </setBody> <transform> <jq>{ "errorDto": . }</jq> </transform> <stop/> </when> </choice> <transform> <jq><![CDATA[ .files | group_by(.fileIdentity) | map( { key: .[0].fileIdentity, value: ( (if any(.[]; .isError) then{ error: {sharePath: .[].sharePath} + ([ .[]| select(.isError)| (.fileName)| select(. != null)] | if length > 0 then{ searchPath: (join("&lt;br&gt;")) }else {}end) }else { files: [ .[] | .fileData | select(. != null) ] }end) ) } ) | from_entries ]]></jq> </transform> <setBody> <simple> ${jq("(property("originalBody") | fromjson) + .")} </simple> </setBody> <transform> <jq>{ "response": ( . | tostring ) }</jq> </transform> </route>';

  -- Аналог APEX_APPLICATION_GLOBAL.VC_ARR2 из пакета APEX_UTIL
  TYPE vc_arr2 IS TABLE OF VARCHAR2(32767) INDEX BY BINARY_INTEGER;


    /**************************************************************************************************\
      [Начало блока] BIQ-34452(avt) Контроль за статусом и сроками представления отчетности в БР
      Изменения:
      --------------------------------------------------------------------------------------------------------------
      Дата        Автор            Jira                                    Описание
      ----------  ---------------  --------------------------------------  -----------------------------------------
      19.03.2026  Борисов Т.Ю.     BIQ-34452                               Создание

      \**************************************************************************************************/
    -- =============================================================================
    -- Добавление в отчет тегов p_tag_name / p_tag_value
    -- =============================================================================
    FUNCTION EnrichReportJson(
        p_json_input CLOB,
        p_report_tag VARCHAR2,
        p_tag_name VARCHAR2,
        p_tag_value VARCHAR2
    ) RETURN CLOB
        IS
        v_json_array JSON_ARRAY_T;
        v_json_obj   JSON_OBJECT_T;
        v_body_obj   JSON_OBJECT_T;
        v_report_obj JSON_OBJECT_T;
        v_result     CLOB;
        v_log_prefix VARCHAR2(100) := 'ControlDateReport ControlDate_EnrichJson';
    BEGIN

        v_json_array := JSON_ARRAY_T.parse(p_json_input);
        v_json_obj := JSON_OBJECT_T(v_json_array.get(0));
        v_body_obj := JSON_OBJECT_T(v_json_obj.get('body'));
        v_report_obj := JSON_OBJECT_T(v_body_obj.get(p_report_tag));
        v_report_obj.put(p_tag_name, p_tag_value);
        v_body_obj.put(p_report_tag, v_report_obj);
        v_json_obj.put('body', v_body_obj);
        v_json_array := JSON_ARRAY_T();
        v_json_array.append(v_json_obj);
        v_result := v_json_array.to_clob();

        RETURN v_result;
    EXCEPTION
        WHEN OTHERS THEN
            it_log.log(v_log_prefix || ' ERROR: ' || SQLERRM, it_log.C_MSG_TYPE__ERROR);
            RETURN p_json_input;
    END EnrichReportJson;

    -- =============================================================================
    -- UI
    -- =============================================================================
    FUNCTION ControlDateMetaUI
        RETURN CLOB
        IS
        C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
        C_REPORT_LOCALIZED_NAME VARCHAR2(64)  := 'Контроль за статусом и сроками представления отчетности в БР';
        C_SYS_TAGS              VARCHAR2(256) := '["ORACLE_DEBUG", "BR"]';
        v_meta_ui               CLOB;
    BEGIN
        SELECT JSON_OBJECT(
                       C_META_UI_TAG__ROLES VALUE C_ROLES FORMAT JSON,
                       C_META_UI_TAG__LABEL VALUE C_REPORT_LOCALIZED_NAME,
                       C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
                       C_META_UI_TAG__FORM VALUE JSON_ARRAY(
                               JSON_ARRAY(
                                       JSON_OBJECT(
                                               'label' VALUE 'Дата с',
                                               'name' VALUE 'beginDate',
                                               'type' VALUE 'date',
                                               'required' VALUE 'true' FORMAT JSON,
                                               'column' VALUE 0,
                                               'default' VALUE TO_CHAR(SYSDATE - 7, 'YYYY-MM-DD')
                                       )
                               ),
                               JSON_ARRAY(
                                       JSON_OBJECT(
                                               'label' VALUE 'Дата по',
                                               'name' VALUE 'endDate',
                                               'type' VALUE 'date',
                                               'required' VALUE 'true' FORMAT JSON,
                                               'column' VALUE 0,
                                               'default' VALUE TO_CHAR(SYSDATE, 'YYYY-MM-DD')
                                       ),
                                       JSON_OBJECT(
                                               'label' VALUE 'Список отчетов',
                                               'name' VALUE 'reportName',
                                               'type' VALUE 'select',
                                               'required' VALUE 'true' FORMAT JSON,
                                               'column' VALUE 1,
                                               'default' VALUE (SELECT JSON_ARRAYAGG(T_FORM RETURNING VARCHAR2(32767))
                                                                FROM (SELECT DISTINCT T_FORM,
                                                                                      FIRST_VALUE(T_DESC) OVER (PARTITION BY T_FORM ORDER BY T_SINCEDATE DESC) AS T_DESC
                                                                      FROM DBDUI_REPORTCONTROLDATE_DBT
                                                                      WHERE T_SINCEDATE <= SYSDATE
                                                                      ORDER BY T_FORM)),
                                               'multiselect' VALUE 'true' FORMAT JSON,
                                               'items' VALUE (SELECT JSON_ARRAYAGG(
                                                                             JSON_OBJECT('name' VALUE T_DESC, 'value' VALUE T_FORM)
                                                                             RETURNING VARCHAR2(32767)
                                                                     )
                                                              FROM (SELECT DISTINCT T_FORM,
                                                                                    FIRST_VALUE(T_DESC) OVER (PARTITION BY T_FORM ORDER BY T_SINCEDATE DESC) AS T_DESC
                                                                    FROM DBDUI_REPORTCONTROLDATE_DBT
                                                                    WHERE T_SINCEDATE <= SYSDATE
                                                                    ORDER BY T_FORM))
                                       )
                               )
                                                 ) RETURNING CLOB
               )
        INTO v_meta_ui
        FROM dual;
        RETURN v_meta_ui;
    END ControlDateMetaUI;

    -- =============================================================================
    -- парсинг строки в период
    -- =============================================================================
    PROCEDURE ControlDate_ParseInterval(p_interval VARCHAR2, p_offset OUT INTEGER, p_unit OUT VARCHAR2)
        IS
    BEGIN
        p_offset := TO_NUMBER(REGEXP_SUBSTR(p_interval, '\d+'));
        p_unit := REGEXP_SUBSTR(p_interval, '[A-Za-z]$');
    END ControlDate_ParseInterval;

    -- =============================================================================
    -- обработка отдельно взятого отчета
    -- =============================================================================
    FUNCTION ControlDate_ProcessForm(
        p_trace_id_input VARCHAR2,
        p_form_name VARCHAR2,
        p_date_begin DATE,
        p_date_end DATE
    ) RETURN CLOB
        IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        C_EMPTY_JSON_ARRAY CONSTANT CLOB         := TO_CLOB('[]');
        C_PARSE_FORM_ERROR CONSTANT VARCHAR2(60) := 'Ошибка при обработке формы ''';
        C_FORM_NOT_FOUND   CONSTANT VARCHAR2(60) := 'ERROR: форма не найдена в справочнике на дату <=';
        C_NO_ACTIVE_RECORD CONSTANT VARCHAR2(60) := ' SKIP: no active record for period starting ';

        v_json_output               CLOB         := C_EMPTY_JSON_ARRAY;
        v_control_date_rec          DBDUI_REPORTCONTROLDATE_DBT%ROWTYPE;
        v_work_date                 DATE;
        v_period_start              DATE; -- начало учётного периода (месяц/квартал/год)
        v_next_period_start         DATE; -- начало следующего периода ? начало отчётного окна
        v_current_date              DATE;
        v_period_offset             INTEGER;
        v_period_unit               VARCHAR2(1);
        v_exists                    NUMBER;
        v_result_array              JSON_ARRAY_T := JSON_ARRAY_T();
        v_form_desc                 VARCHAR2(256);
        v_kind                      NUMBER;
        v_log_prefix                VARCHAR2(512);
    BEGIN
        v_log_prefix :=
                'traceId=''' || COALESCE(p_trace_id_input, 'NULL') ||
                ''' form=''' ||
                p_form_name || '''';

        -- Определяем тип отчётности
        BEGIN
            SELECT T_KIND
            INTO v_kind
            FROM (SELECT T_KIND
                  FROM DBDUI_REPORTCONTROLDATE_DBT
                  WHERE T_FORM = p_form_name
                    AND T_SINCEDATE <= p_date_end
                  ORDER BY T_SINCEDATE DESC)
            WHERE ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                it_log.log(
                        v_log_prefix || C_FORM_NOT_FOUND ||
                        TO_CHAR(p_date_end, 'YYYY-MM-DD'),
                        it_log.C_MSG_TYPE__ERROR);
                RAISE_APPLICATION_ERROR(-20001, 'Форма ' || p_form_name || ' не найдена в справочнике');
        END;

        -- Устанавливаем начальную дату генерации с запасом
        CASE v_kind
            WHEN 12 THEN v_current_date := TRUNC(ADD_MONTHS(p_date_begin, -1), 'MM');
            WHEN 4 THEN v_current_date := TRUNC(ADD_MONTHS(p_date_begin, -3), 'Q');
            WHEN 1 THEN v_current_date := TRUNC(ADD_MONTHS(p_date_begin, -12), 'YYYY');
            ELSE v_current_date := p_date_begin - 30;
            END CASE;

        WHILE v_current_date <= p_date_end
        LOOP
            -- === ШАГ 1: Определяем учётный период и начало отчётного окна ===
            CASE v_kind
                WHEN 12 THEN v_period_start := TRUNC(v_current_date, 'MM');
                             v_next_period_start := ADD_MONTHS(v_period_start, 1);
                             v_current_date := v_next_period_start;
                WHEN 4 THEN v_period_start := TRUNC(v_current_date, 'Q');
                            v_next_period_start := ADD_MONTHS(v_period_start, 3);
                            v_current_date := v_next_period_start;
                WHEN 1 THEN v_period_start := TRUNC(v_current_date, 'YYYY');
                            v_next_period_start := ADD_MONTHS(v_period_start, 12);
                            v_current_date := v_next_period_start;
                ELSE v_period_start := v_current_date;
                     v_next_period_start := v_current_date + 1;
                     v_current_date := v_next_period_start;
                END CASE;

            -- === ШАГ 2: Получаем актуальную запись справочника на дату учётного периода ===
            BEGIN
                SELECT *
                INTO v_control_date_rec
                FROM (SELECT *
                      FROM DBDUI_REPORTCONTROLDATE_DBT
                      WHERE T_FORM = p_form_name
                        AND T_SINCEDATE <= v_period_start
                      ORDER BY T_SINCEDATE DESC)
                WHERE ROWNUM = 1;

            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    it_log.log(
                            v_log_prefix || C_NO_ACTIVE_RECORD ||
                            TO_CHAR(v_period_start, 'YYYY-MM-DD'),
                            it_log.C_MSG_TYPE__DEBUG);
                    CONTINUE;
            END;

            v_form_desc := v_control_date_rec.T_DESC;
            ControlDate_ParseInterval(v_control_date_rec.T_INTERVAL, v_period_offset, v_period_unit);

            -- === ШАГ 3: Рассчитываем контрольную дату ===
            v_work_date := v_next_period_start;

             -- Применяем исключение ДО обычного смещения
            IF p_form_name = '0409708'
                AND v_control_date_rec.T_KIND = 4
                AND EXTRACT(MONTH FROM v_period_start) = 10 THEN
                -- Q4 ? всегда 15 февраля следующего года
                v_work_date := ADD_MONTHS(TRUNC(v_period_start, 'YYYY'), 13) + 14;
                it_log.log(v_log_prefix || ' SPECIAL RULE 0409708 (Q4): overridden work date to ' ||
                           TO_CHAR(v_work_date, 'DD.MM.YYYY'), it_log.C_MSG_TYPE__DEBUG);
            ELSE
                -- Обычная логика: применяем смещение
                IF v_period_unit = 'D' THEN
                    v_work_date := RSI_RSBCALENDAR.GetDateAfterWorkDay(v_work_date, v_period_offset);
                ELSIF v_period_unit = 'M' THEN
                    v_work_date := ADD_MONTHS(v_work_date, v_period_offset);
                ELSE
                    v_work_date := v_work_date + v_period_offset;
                END IF;
            END IF;

            -- === ШАГ 4: Проверяем ПЕРЕСЕЧЕНИЕ отчётного окна с запрашиваемым периодом ===
            -- Отчётное окно: [v_next_period_start, v_work_date]
            -- Запрашиваемый период: [p_date_begin, p_date_end]
            IF p_date_begin <= v_work_date AND v_next_period_start <= p_date_end THEN
                -- Попадает: есть пересечение
                SELECT COUNT(*)
                INTO v_exists
                FROM DBDUI_REPORTPOSTINFO_DBT
                WHERE T_FORM = p_form_name
                  AND T_LIMITDATE = v_work_date;
                IF v_exists = 0 THEN
                    INSERT INTO DBDUI_REPORTPOSTINFO_DBT (T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS,
                                                          T_MESSAGE,
                                                          T_ADDTIME)
                    VALUES (p_form_name, v_work_date, NULL, NULL, NULL, NULL, SYSTIMESTAMP);

                END IF;
                v_result_array.append(
                        JSON_OBJECT_T(
                                JSON_OBJECT(
                                        'report_form' VALUE v_form_desc,
                                        'lim_date' VALUE TO_CHAR(v_work_date, 'DD.MM.YYYY'),
                                        'send_day' VALUE '',
                                        'reg_day' VALUE '',
                                        'status' VALUE '',
                                        'mess' VALUE '',
                                        'date' VALUE '',
                                        'date_end' VALUE TO_CHAR(p_date_end, 'DD.MM.YYYY')
                                )
                        )
                );
            END IF;
        END LOOP;

        COMMIT;
        IF v_result_array.get_size() = 0 THEN
            v_json_output := C_EMPTY_JSON_ARRAY;
        ELSE
            v_json_output := v_result_array.to_clob();
        END IF;

        RETURN v_json_output;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            it_error.put_error_in_stack;
            it_log.log(v_log_prefix || ' FATAL ERROR: ' || SQLERRM, it_log.C_MSG_TYPE__ERROR);
            RAISE_APPLICATION_ERROR(-20001, C_PARSE_FORM_ERROR || p_form_name || ''': ' || SQLERRM);
    END ControlDate_ProcessForm;

    -- =============================================================================
    -- основная функция
    -- =============================================================================
    FUNCTION ControlDate_RC_ReportRun(
        p_trace_id_input VARCHAR2,
        p_json_input CLOB,
        p_is_production CHAR DEFAULT '1'
    ) RETURN CLOB
        IS
        C_TEMPLATE_NAME CONSTANT        VARCHAR2(128) := 'limit_day_report';
        C_OUTPUT_FILE_NAME_PRE CONSTANT VARCHAR2(128) := 'Контрольные_даты_отчетности_БР';
        C_S3_FILE_NAME CONSTANT         VARCHAR2(128) := 'control_dates_report_';
        C_REPORT_NAME_TAG CONSTANT      VARCHAR2(128) := 'GetLmitDayReport';
        C_ITEMS_ARR_TAG CONSTANT        VARCHAR2(128) := 'LimitDay_info';
        C_IN_BEGIN_DATE_TAG CONSTANT    VARCHAR2(32)  := 'beginDate';
        C_IN_END_DATE_TAG CONSTANT      VARCHAR2(32)  := 'endDate';
        C_IN_DATE_FORMAT CONSTANT       VARCHAR2(32)  := 'YYYY-MM-DD';
        C_ERR_01_CODE CONSTANT          VARCHAR2(8)   := 'ER_01';
        C_ERR_01_MSG CONSTANT           VARCHAR2(128) := 'СОФР не смог сформировать отчет: Дата начала (%s) не может быть больше даты окончания (%s)';
        C_ERR_99_CODE CONSTANT          VARCHAR2(8)   := 'ER_99';
        C_ERR_99_MSG CONSTANT           VARCHAR2(64)  := 'СОФР не смог сформировать отчет: другая ошибка';
        C_EMPTY_JSON_ARRAY CONSTANT     CLOB          := TO_CLOB('[]');

        v_json_obj                      JSON_OBJECT_T;
        v_date_begin                    DATE;
        v_date_end                      DATE;
        v_report_name_list              JSON_ARRAY_T;
        v_final_json                    JSON_ARRAY_T  := JSON_ARRAY_T();
        v_single_form_json              CLOB;
        v_json_output                   CLOB;
        v_errors_array                  JSON_ARRAY_T  := JSON_ARRAY_T();
        v_has_any_param                 BOOLEAN       := FALSE;
        v_json_clob                     CLOB          := C_EMPTY_JSON_ARRAY;
    BEGIN
        IF p_json_input IS NULL OR p_json_input = '{}' OR p_json_input = '[]' THEN
            RETURN BuildJsonOutput(p_body => ControlDateMetaUI());
        END IF;
        v_json_obj := JSON_OBJECT_T.parse(p_json_input);
        v_date_begin := TO_DATE(v_json_obj.get_string(C_IN_BEGIN_DATE_TAG), C_IN_DATE_FORMAT);
        v_has_any_param := TRUE;
        v_date_end := TO_DATE(v_json_obj.get_string(C_IN_END_DATE_TAG), C_IN_DATE_FORMAT);

        IF v_date_begin > v_date_end THEN
            v_errors_array.append(GetErrorObjAndLog(
                    p_trace_id_input, C_ERR_01_CODE,
                    UTL_LMS.FORMAT_MESSAGE(C_ERR_01_MSG,
                                           TO_CHAR(v_date_begin, 'DD.MM.YYYY'), TO_CHAR(v_date_end, 'DD.MM.YYYY'))
                                  ));
            it_log.log('traceId=''' || p_trace_id_input ||
                       ''' Invalid date range',
                       it_log.C_MSG_TYPE__DEBUG);
            RETURN BuildJsonOutput(p_errors_array => v_errors_array);
        END IF;

        -- Получаем уникальные и актуальные формы
        IF v_report_name_list IS NULL OR v_report_name_list.get_size() = 0 THEN
            BEGIN
                SELECT COALESCE(JSON_ARRAYAGG(T_FORM RETURNING CLOB), C_EMPTY_JSON_ARRAY)
                INTO v_json_clob
                FROM (SELECT DISTINCT T_FORM,
                                      FIRST_VALUE(T_DESC) OVER (PARTITION BY T_FORM ORDER BY T_SINCEDATE DESC) AS T_DESC
                      FROM DBDUI_REPORTCONTROLDATE_DBT
                      WHERE T_SINCEDATE <= SYSDATE
                      ORDER BY T_FORM);
            EXCEPTION
                WHEN OTHERS THEN
                    it_log.log('traceId=''' || p_trace_id_input ||
                               ''' Error fetching forms: ' || SQLERRM, it_log.C_MSG_TYPE__ERROR);
                    v_json_clob := C_EMPTY_JSON_ARRAY;
            END;

            v_report_name_list := JSON_ARRAY_T.parse(v_json_clob);
        END IF;

        FOR i IN 0 .. v_report_name_list.get_size() - 1
        LOOP
            DECLARE
                v_form_name  VARCHAR2(60);
                v_form_array JSON_ARRAY_T;
            BEGIN
                    v_form_name := v_report_name_list.get(i).to_string();
                    v_form_name := TRIM(BOTH '"' FROM v_form_name);

                v_single_form_json :=
                            ControlDate_ProcessForm(p_trace_id_input, v_form_name, v_date_begin, v_date_end);

                it_log.log('traceId=''' || p_trace_id_input ||
                           ''' v_single_form_json for form ''' || v_form_name || ''': ' ||
                           DBMS_LOB.SUBSTR(COALESCE(v_single_form_json, TO_CLOB('NULL')), 2000, 1),
                           it_log.C_MSG_TYPE__DEBUG);

                IF v_single_form_json IS NOT NULL AND
                   DBMS_LOB.COMPARE(v_single_form_json, C_EMPTY_JSON_ARRAY) != 0 THEN
                    v_form_array := JSON_ARRAY_T.parse(v_single_form_json);
                    FOR j IN 0 .. v_form_array.get_size() - 1
                        LOOP
                            v_final_json.append(JSON_OBJECT_T(v_form_array.get(j)));
                        END LOOP;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    it_log.log('traceId=''' || p_trace_id_input ||
                               ''' Error processing form ''' || v_form_name || ''': ' || SQLERRM,
                               it_log.C_MSG_TYPE__ERROR);
                    v_final_json.append(
                            JSON_OBJECT_T(
                                    JSON_OBJECT(
                                            'report_form' VALUE v_form_name,
                                            'lim_date' VALUE '',
                                            'send_day' VALUE '',
                                            'reg_day' VALUE '',
                                            'status' VALUE 'ОШИБКА',
                                            'mess' VALUE 'Ошибка обработки: ' || SQLERRM,
                                            'date' VALUE '',
                                            'date_end' VALUE TO_CHAR(v_date_end, 'DD.MM.YYYY')
                                    )
                            )
                    );
            END;
        END LOOP;

        IF v_final_json.get_size() = 0 THEN
            it_log.log('traceId=''' || p_trace_id_input || ''' No data found',
                       it_log.C_MSG_TYPE__DEBUG);
            DECLARE
                v_empty_body CLOB;
            BEGIN
                SELECT JSON_OBJECT(
                               C_REPORT_NAME_TAG VALUE JSON_OBJECT(
                                'date' VALUE SYSDATE,
                                'date_begin' VALUE TO_CHAR(v_date_begin, 'DD.MM.YYYY'),
                                'date_end' VALUE TO_CHAR(v_date_end, 'DD.MM.YYYY'),
                                C_ITEMS_ARR_TAG VALUE '[]'
                                                       )
                       )
                INTO v_empty_body
                FROM dual;
                v_json_output := BuildJsonOutput(p_body => v_empty_body);
            END;
        ELSE
            v_json_output := v_final_json.to_clob();
        END IF;

        v_json_output := BuildSplitJsonOutput(
                p_trace_id_input => p_trace_id_input,
                p_json_input => v_json_output,
                p_report_date_input => v_date_begin,
                p_report_tag => C_REPORT_NAME_TAG,
                p_items_arr_tag => C_ITEMS_ARR_TAG,
                p_template_name => C_TEMPLATE_NAME,
                p_output_file_name => C_OUTPUT_FILE_NAME_PRE,
                p_s3_file_name => C_S3_FILE_NAME
                         );

        v_json_output := EnrichReportJson(
                p_json_input => v_json_output,
                p_report_tag => C_REPORT_NAME_TAG,
                p_tag_name => 'date_begin',
                p_tag_value => TO_CHAR(v_date_begin, 'DD.MM.YYYY')
                         );

        v_json_output := EnrichReportJson(
                p_json_input => v_json_output,
                p_report_tag => C_REPORT_NAME_TAG,
                p_tag_name => 'date_end',
                p_tag_value => TO_CHAR(v_date_end, 'DD.MM.YYYY')
                         );

        it_log.log('traceId=''' || COALESCE(p_trace_id_input, 'NULL') ||
                   ''' RETURNING result (first 2000 chars): ' ||
                   DBMS_LOB.SUBSTR(COALESCE(v_json_output, TO_CLOB('NULL')), 2000, 1), it_log.C_MSG_TYPE__DEBUG);

        RETURN v_json_output;
    EXCEPTION
        WHEN OTHERS THEN
            it_error.put_error_in_stack;
            IF v_errors_array.get_size() = 0 THEN
                v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                        C_ERR_99_MSG || ': ' || SQLERRM));
            END IF;
            RETURN BuildJsonOutput(p_errors_array => v_errors_array);
    END ControlDate_RC_ReportRun;
    /**************************************************************************************************\
    [Конец блока] BIQ-34452(avt) Контроль за статусом и сроками представления отчетности в БР
    \**************************************************************************************************/

END IT_CheckLimitReport;
/
