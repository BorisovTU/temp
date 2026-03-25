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

  C_PERIOD CONSTANT SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST(
    'Январь','Февраль','Март','Апрель','Май','Июнь',
    'Июль','Август','Сентябрь','Октябрь','Ноябрь','Декабрь',
    'Первый квартал', 'Второй квартал', 'Третий квартал',
    'Четвертый квартал');

  -- Аналог APEX_APPLICATION_GLOBAL.VC_ARR2 из пакета APEX_UTIL
  TYPE vc_arr2 IS TABLE OF VARCHAR2(32767) INDEX BY BINARY_INTEGER;

  /************************************************************************************************************\
  [Начало блока] Сверка остатков по позициям клиентов на утро (СОФР - QUIK)
  **************************************************************************************************************
  Изменения:
  --------------------------------------------------------------------------------------------------------------
  Дата        Автор            Jira                                    Описание
  ----------  ---------------  --------------------------------------  -----------------------------------------
  06.08.2025  Логинов Н.А.     BIQ-23781.1(intech), BIQ-29457.1(avt)   Создание
  \*************************************************************************************************************/

  --------------------------------------------------------------------------------------------------------------------
  ----- Преобразует строку в NUMBER с учётом локали БД -----
  --------------------------------------------------------------------------------------------------------------------
  FUNCTION ToLocalNumber(p_value VARCHAR2)
    RETURN NUMBER
  IS
  BEGIN
    RETURN TO_NUMBER(REPLACE(p_value, ',', '.'), '99999999999999999999.999999999999');
  END ToLocalNumber;

  FUNCTION JsonBoolToNumber(
      p_bool     BOOLEAN,
      p_default  NUMBER := 0
  ) RETURN NUMBER
      IS
  BEGIN
      IF p_bool IS NULL THEN
          RETURN p_default;
      ELSIF p_bool THEN
          RETURN 1;
      ELSE
          RETURN 0;
      END IF;
  EXCEPTION
      WHEN OTHERS THEN
          RETURN p_default;
  END JsonBoolToNumber;

  FUNCTION AppendIfNotNull(p_json_arr IN OUT NOCOPY JSON_ARRAY_T, p_value JSON_OBJECT_T)
    RETURN BOOLEAN
  IS
  BEGIN
    IF p_value IS NOT NULL THEN
      p_json_arr.APPEND(p_value);
      RETURN TRUE;
    END IF;
    RETURN FALSE;
  END;

  ----------------------------------------------------------
  ----- Получение массива SYS.ODCIVARCHAR2LIST из JSON -----
  ----------------------------------------------------------
  FUNCTION GetArrayFromJsonField(p_json_input CLOB, p_field_name_input VARCHAR2)
    RETURN SYS.ODCIVARCHAR2LIST
  IS
    v_result SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
    v_sql    VARCHAR2(2048);
  BEGIN
    IF p_json_input IS NULL THEN
      RETURN v_result;
    END IF;

    v_sql := '
        SELECT value
        FROM JSON_TABLE(
            :json_data,
            ''$.' || p_field_name_input || '[*]''
            COLUMNS (
                value VARCHAR2(4000) PATH ''$''
            )
        )
        WHERE value IS NOT NULL';

    EXECUTE IMMEDIATE v_sql
      BULK COLLECT INTO v_result
      USING p_json_input;

    RETURN v_result;
  EXCEPTION
    WHEN OTHERS THEN
      -- Если ключа нет или формат невалиден, вернем пустой список
      RETURN SYS.ODCIVARCHAR2LIST();
  END GetArrayFromJsonField;

  ---------------------------------------------------------
  ----- Формирование заголовков для Фабрики документов ----
  ---------------------------------------------------------
  FUNCTION GetDocFactHeaders(p_trace_id_input             VARCHAR2,
                             p_report_date_input          DATE,   -- Nullable
                             p_template_name_input        VARCHAR2,
                             p_output_file_name_input     VARCHAR2,
                             p_s3_file_name_input         VARCHAR2,
                             p_part_num_input             INTEGER DEFAULT 1, -- Порядковый номер части отчёта
                             p_total_parts_input          INTEGER DEFAULT 1, -- Общее количество частей отчёта
                             p_request_time               VARCHAR2 DEFAULT NULL, -- timestamp в формате ISO8601, если не передан, берётся IT_XML.TIMESTAMP_TO_CHAR_ISO8601(sysdate)
                             p_report_date_format         VARCHAR2 DEFAULT 'YYYY.MM.DD' -- Формат даты в выходном наименовании файла
  )
    RETURN CLOB
  IS
    v_request_id             VARCHAR2(64);
    v_raw_request_time       VARCHAR2(64);
    v_formated_request_time  VARCHAR2(64);
    p_file_name_postfix      VARCHAR2(128);
    p_s3_file_name_postfix   VARCHAR2(128);
    v_report_date_part       VARCHAR2(128);
    v_s3_report_date_part    VARCHAR2(128);
  BEGIN
    IF (p_template_name_input IS NULL) THEN
      RETURN '';
    END IF;
    -- GUID запроса из СОФР
    SELECT cast(sys_guid() AS VARCHAR2(32)) AS GUID INTO v_request_id FROM DUAL;
    -- Получаем Дату и время регистрации запроса в СОФР
    IF (p_request_time IS NULL) THEN
      SELECT IT_XML.TIMESTAMP_TO_CHAR_ISO8601(sysdate) INTO v_raw_request_time FROM DUAL;
    ELSE
      v_raw_request_time := p_request_time;
    END IF;
    v_formated_request_time := '_' || TO_CHAR(
            TO_TIMESTAMP(v_raw_request_time, 'YYYY-MM-DD"T"HH24:MI:SS.FF3'),
            'YYYY.MM.DD_HH24.MI.SS');
    -- Постфиксы частей
    p_file_name_postfix := CASE
                             WHEN p_total_parts_input > 1
                               THEN '_' || p_part_num_input || 'из' || p_total_parts_input
                             ELSE ''
                           END;
    p_s3_file_name_postfix := CASE
                                WHEN p_total_parts_input > 1
                                  THEN '_' || p_part_num_input || 'of' || p_total_parts_input
                                ELSE ''
                              END;

    IF p_report_date_input IS NULL THEN
      -- Не добавляем дату
      v_report_date_part    := '';
      v_s3_report_date_part := '';
    ELSE
      v_report_date_part    := '_за_' || TO_CHAR(p_report_date_input, p_report_date_format);
      v_s3_report_date_part := TO_CHAR(p_report_date_input, p_report_date_format);
    END IF;

    -- Собираем JSON
    RETURN JSON_OBJECT(
      'x-trace-id'         VALUE p_trace_id_input,
      'x-request-time'     VALUE v_raw_request_time,
      'x-request-id'       VALUE v_request_id,
      'x-template-type'    VALUE 'jrxml',
      'x-template-name'    VALUE p_template_name_input,
      'x-system-from'      VALUE 'SOFR',
      'x-output-type'      VALUE 'XLSX',
      'x-output-file-name' VALUE p_output_file_name_input || v_report_date_part || '_от' || v_formated_request_time || p_file_name_postfix || '.xlsx',
      'x-data-source'      VALUE 'S3',
      'x-data-file-name'   VALUE p_s3_file_name_input || v_s3_report_date_part || '_from' || v_formated_request_time || p_s3_file_name_postfix,
      'x-out-bucket-name'  VALUE 'ips-document-factory',
      'x-out-path'         VALUE 'documents/SOFR/' || p_template_name_input || '/'
     );
  END;

  -----------------------------------------------------------------------------------
  ----- Логирует ошибку пакетом IT_LOG и возвращает ошибку в виде JSON_OBJECT_T -----
  ----- для формирования ответного JSON с ошибками -----
  -----------------------------------------------------------------------------------
  FUNCTION GetErrorObjAndLog(p_trace_id VARCHAR2, p_error_code VARCHAR2, p_error_message VARCHAR2)
    RETURN JSON_OBJECT_T
  IS
    -- Константы
    C_ERR_CODE_TAG     CONSTANT VARCHAR2(16) := 'errorCode';
    C_ERR_MSG_TAG      CONSTANT VARCHAR2(16) := 'errorMessage';

    v_err_obj          JSON_OBJECT_T := JSON_OBJECT_T();
  BEGIN
    -- Логируем в IT_LOG
    it_log.log(p_msg => 'traceId=''' || p_trace_id || ''' ' || p_error_code || ' ' || p_error_message,
               p_msg_type => it_log.C_MSG_TYPE__ERROR
    );
    it_error.clear_error_stack;

    -- Собираем объект ошибки
    v_err_obj.put(C_ERR_CODE_TAG, p_error_code);
    v_err_obj.put(C_ERR_MSG_TAG, p_error_message);

    RETURN v_err_obj;
  END GetErrorObjAndLog;

  -----------------------------------------------------------------------------------
  ----- Безопасно формирует выходной JSON общего вида -----
  ----- НЕ рекомендуется для больших CLOB'ов, т.к. они парсятся в JSON_OBJECT_T -----
  -----------------------------------------------------------------------------------
  FUNCTION BuildJsonOutput (
      p_headers      CLOB DEFAULT '',
      p_body         CLOB DEFAULT '',
      p_exmeta_array JSON_ARRAY_T DEFAULT JSON_ARRAY_T(),
      p_errors_array JSON_ARRAY_T DEFAULT JSON_ARRAY_T()
  )
      RETURN CLOB
  IS
      v_json_obj   JSON_OBJECT_T := JSON_OBJECT_T();
      v_json_array JSON_ARRAY_T  := JSON_ARRAY_T();
  BEGIN
      v_json_obj.put(C_OUTPUT_TAG__HEADERS,
                     CASE
                         WHEN p_headers IS NULL OR trim(p_headers) = ''
                             THEN JSON_OBJECT_T()
                         ELSE json_object_t.parse(p_headers)
                     END);

      v_json_obj.put(C_OUTPUT_TAG__BODY, CASE
                                     WHEN p_body IS NULL OR trim(p_body) = ''
                                         THEN JSON_OBJECT_T()
                                     ELSE json_object_t.parse(p_body)
                                 END);
      v_json_obj.put(C_OUTPUT_TAG__EXMETA, COALESCE(p_exmeta_array, JSON_ARRAY_T())); -- сюда потом будем класть что-нибудь полезное
      v_json_obj.put(C_OUTPUT_TAG__ERRORS, COALESCE(p_errors_array, JSON_ARRAY_T()));

      v_json_array.append(v_json_obj);

      RETURN v_json_array.to_clob;
  END BuildJsonOutput;

  FUNCTION BuildSplitJsonOutput(
    p_trace_id_input     VARCHAR2,
    p_json_input         CLOB,
    p_report_date_input  DATE,  -- Nullable
    p_report_tag         VARCHAR2, -- например: 'GetDepoReport'
    p_items_arr_tag      VARCHAR2, -- например: 'Rest_info'
    p_template_name      VARCHAR2,
    p_output_file_name   VARCHAR2,
    p_s3_file_name       VARCHAR2,
    p_report_date_format VARCHAR2 DEFAULT 'YYYY.MM.DD' -- Формат даты в выходном наименовании файла
  )
    RETURN CLOB
  IS
    v_json_output  CLOB;
    v_total_parts  INTEGER;
  BEGIN
    -- Разбиваем большой JSON на части
    v_total_parts := SplitJsonArrayIntoParts(p_json_input, C_MAX_DATA_SIZE_PER_PART);

    -- Собираем обратно общий JSON из временной таблицы
    SELECT JSON_ARRAYAGG(
        JSON_OBJECT(
            C_OUTPUT_TAG__EXMETA VALUE '[]' FORMAT JSON,
            C_OUTPUT_TAG__HEADERS VALUE GetDocFactHeaders(
                p_trace_id_input,
                p_report_date_input,
                p_template_name,
                p_output_file_name,
                p_s3_file_name,
                part_num,
                v_total_parts,
                IT_XML.TIMESTAMP_TO_CHAR_ISO8601(SYSDATE),
                p_report_date_format
            ) FORMAT JSON,
            C_OUTPUT_TAG__BODY VALUE JSON_OBJECT(
                p_report_tag VALUE JSON_OBJECT(
                    'date' VALUE CASE
                                   WHEN p_report_date_input IS NOT NULL THEN TO_CHAR(p_report_date_input, 'DD.MM.YYYY')
                                 END,
                    p_items_arr_tag VALUE json_part FORMAT JSON
                 ABSENT ON NULL) RETURNING CLOB
            ) RETURNING CLOB
        ) RETURNING CLOB
    )
    INTO v_json_output
    FROM dbdui_report_parts_dbt;

    RETURN v_json_output;
  END BuildSplitJsonOutput;

  FUNCTION BuildDerivativesSplitJsonOutput(
    p_trace_id_input      VARCHAR2,
    p_json_input          CLOB,
    p_report_date_input   DATE,
    p_report_tag          VARCHAR2, -- например: 'GetDepoReport'
    p_items_arr_tag       VARCHAR2, -- например: 'deals', или 'deals_op'
    p_template_name       VARCHAR2,
    p_output_file_name    VARCHAR2,
    p_s3_file_name        VARCHAR2,
    p_dummy_items_arr_tag VARCHAR2, -- тег массива-заглушки
    p_dummy_items_arr     CLOB      -- заглушка с правильной структурой futures/options, и с NULL в значениях, для работы Jasper
  )
    RETURN CLOB
  IS
    v_json_output      CLOB;
    v_total_parts      INTEGER;
  BEGIN
    -- Разбиваем большой JSON на части
    v_total_parts := SplitJsonArrayIntoParts(p_json_input, C_MAX_DATA_SIZE_PER_PART);

    -- Собираем обратно общий JSON из временной таблицы
    SELECT JSON_ARRAYAGG(
        JSON_OBJECT(
            C_OUTPUT_TAG__EXMETA VALUE '[]' FORMAT JSON,
            C_OUTPUT_TAG__HEADERS VALUE GetDocFactHeaders(
                p_trace_id_input,
                p_report_date_input,
                p_template_name,
                p_output_file_name,
                p_s3_file_name,
                part_num,
                v_total_parts,
                IT_XML.TIMESTAMP_TO_CHAR_ISO8601(SYSDATE)
            ) FORMAT JSON,
            C_OUTPUT_TAG__BODY VALUE JSON_OBJECT(
                p_report_tag VALUE JSON_OBJECT(
                    'date' VALUE TO_CHAR(p_report_date_input, 'DD.MM.YYYY'),
                    p_items_arr_tag VALUE json_part FORMAT JSON,
                    p_dummy_items_arr_tag VALUE p_dummy_items_arr FORMAT JSON
                ) RETURNING CLOB
            ) RETURNING CLOB
        ) RETURNING CLOB
    )
    INTO v_json_output
    FROM dbdui_report_parts_dbt;

    RETURN v_json_output;
  END BuildDerivativesSplitJsonOutput;

  FUNCTION SplitJsonArrayIntoParts(
    p_json_to_split_input CLOB,
    p_part_limit_bytes    INTEGER
  )
    RETURN INTEGER
  IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    v_part_num        INTEGER := 0;
    v_accum_bytes     INTEGER := 0;
    v_curr_item_bytes INTEGER;
    v_chunk           CLOB;
  BEGIN
    -- Очистим временную таблицу
    DELETE FROM dbdui_report_parts_dbt;

    -- Основной проход по JSON-массиву
    FOR rec IN (
      SELECT jt.elem
      FROM JSON_TABLE(
               p_json_to_split_input,
               '$[*]'
               COLUMNS elem CLOB FORMAT JSON PATH '$'
           ) jt
    )
    LOOP
      v_curr_item_bytes := IT_CheckLimitReport.GetClobUTF8Length(rec.elem);

      IF v_accum_bytes = 0 THEN
        -- Создаём временный CLOB для текущей части
        DBMS_LOB.CREATETEMPORARY(v_chunk, TRUE);
        DBMS_LOB.APPEND(v_chunk, '[');
        v_part_num := v_part_num + 1;
      END IF;

      -- Если добавление превысит лимит, закрываем текущий чанк
      IF v_accum_bytes > 0 AND v_accum_bytes + v_curr_item_bytes + 1 > p_part_limit_bytes THEN
        DBMS_LOB.APPEND(v_chunk, ']');
        INSERT INTO dbdui_report_parts_dbt (PART_NUM, JSON_PART)
        VALUES (v_part_num, v_chunk);

        DBMS_LOB.FREETEMPORARY(v_chunk);
        v_accum_bytes := 0;
      ELSE
        IF  v_accum_bytes > 0 THEN
          DBMS_LOB.APPEND(v_chunk, ',');
        END IF;
        -- Добавляем элемент
        DBMS_LOB.APPEND(v_chunk, rec.elem);
        v_accum_bytes := v_accum_bytes + v_curr_item_bytes;
      END IF;
    END LOOP;

    -- Добавляем последнюю часть
    IF v_accum_bytes > 0 THEN
      DBMS_LOB.APPEND(v_chunk, ']');
      INSERT INTO dbdui_report_parts_dbt (PART_NUM, JSON_PART)
      VALUES (v_part_num, v_chunk);
    END IF;

    DBMS_LOB.FREETEMPORARY(v_chunk);

    COMMIT;
    RETURN v_part_num;
  END SplitJsonArrayIntoParts;

  FUNCTION GetClobUTF8Length(p_clob CLOB)
    RETURN INTEGER
  IS
    v_pos     INTEGER := 1;
    v_len     INTEGER;
    v_chunk   VARCHAR2(32767 CHAR);
    v_total   NUMBER := 0;
  BEGIN
    IF p_clob IS NULL THEN
      RETURN 0;
    END IF;

    v_len := DBMS_LOB.GETLENGTH(p_clob);

    WHILE v_pos <= v_len LOOP
        -- Извлекаем кусок CLOB в VARCHAR2
        v_chunk := DBMS_LOB.SUBSTR(p_clob, 32767, v_pos);

        v_total := v_total + DBMS_LOB.GETLENGTH(UTL_I18N.STRING_TO_RAW(v_chunk, 'UTF8'));

        v_pos := v_pos + 32767;
      END LOOP;

    RETURN v_total;
  END;

  -----------------------------------------------------------------------------
  ----- Формирование UI Form для Отчёта сравнения данных СОФР-QUIK по Д/С -----
  -----------------------------------------------------------------------------
  FUNCTION GetMoneyReportMetaUI
    RETURN CLOB
  IS
    C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
    C_REPORT_LOCALIZED_NAME VARCHAR2(64)  := 'Сверка остатков: СОФР-QUIK, Д/С';
    C_SYS_TAGS              VARCHAR2(256) := '["ORACLE","QUIK"]';
    v_meta_ui               CLOB;
  BEGIN
    WITH currencies AS (
      SELECT CASE WHEN t.t_curr_code = 'SUR' THEN 'RUB' ELSE t.t_curr_code END currency
      FROM ddl_limitcashstock_dbt t
      UNION
      SELECT CASE WHEN t.t_curr_code = 'SUR' THEN 'RUB' ELSE t.t_curr_code END currency
      FROM ddl_limitcashstockarch_dbt t)
    SELECT
      JSON_OBJECT(
        C_META_UI_TAG__ROLES   VALUE C_ROLES FORMAT JSON,
        C_META_UI_TAG__LABEL   VALUE C_REPORT_LOCALIZED_NAME,
        C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
        C_META_UI_TAG__FORM    VALUE JSON_ARRAY(
            -- Первая строка
            JSON_ARRAY(
              JSON_OBJECT(
                'label'    VALUE 'Отчетная дата',
                'name'     VALUE 'reportDate',
                'type'     VALUE 'date',
                'required' VALUE 'true' FORMAT JSON,
                'column'   VALUE 0,
                'default'  VALUE TO_CHAR(sysdate - 1, 'YYYY-MM-DD')
                RETURNING CLOB
              ),
              JSON_OBJECT(
                'label'    VALUE 'ЕКК клиента',
                'name'     VALUE 'clientCode',
                'type'     VALUE 'text',
                'required' VALUE 'false' FORMAT JSON,
                'column'   VALUE 1,
                'default'  VALUE ''
                RETURNING CLOB
              )
            ),
            -- Вторая строка
            JSON_ARRAY(
              JSON_OBJECT(
                'label'    VALUE 'Не выводить счета с 0-ми остатками',
                'name'     VALUE 'excludeZeroBalances',
                'type'     VALUE 'checkBox',
                'required' VALUE 'false' FORMAT JSON,
                'column'   VALUE 0,
                'default'  VALUE 'true' FORMAT JSON
                RETURNING CLOB
              ),
              JSON_OBJECT(
                'label'    VALUE 'ФИО клиента',
                'name'     VALUE 'clientName',
                'type'     VALUE 'text',
                'required' VALUE 'false' FORMAT JSON,
                'column'   VALUE 1,
                'default'  VALUE ''
                RETURNING CLOB
              )
            ),
            -- Третья строка
            JSON_ARRAY(
              JSON_OBJECT(
                'label'    VALUE 'Название актива',
                'name'     VALUE 'currency',
                'type'     VALUE 'select',
                'required' VALUE 'true' FORMAT JSON,
                'column'   VALUE 1,
                'default'  VALUE (
                  SELECT JSON_ARRAYAGG(currency RETURNING CLOB)
                  FROM currencies
                ),
                'multiselect' VALUE 'true' FORMAT JSON,
                'items'       VALUE (
                  SELECT JSON_ARRAYAGG(
                             JSON_OBJECT(
                                 'name'  VALUE currency,
                                 'value' VALUE currency
                             ) RETURNING CLOB
                         )
                  FROM currencies
                )
                RETURNING CLOB
              )
            )
        ) RETURNING CLOB
      )
    INTO v_meta_ui
    FROM dual;

    RETURN v_meta_ui;
  END GetMoneyReportMetaUI;

  -----------------------------------------------------------------
  ----- Формирование Отчёта сравнения данных СОФР-QUIK по д/с -----
  -----------------------------------------------------------------
  FUNCTION Money_RC_ReportRun(p_trace_id_input VARCHAR2,
                              p_json_input CLOB,
                              p_is_production CHAR DEFAULT '1' -- Флаг для режима прода:
                              -- Включает поиск в архивной таблице Ddl_LimitCashStockarch_dbt
                              --  1 - данные будут тянуться из Ddl_LimitCashStock_dbt или Ddl_LimitCashStockarch_dbt в зависимости от даты
                              --  0 - данные будут тянуться из Ddl_LimitCashStock_dbt, архивная таблица Ddl_LimitCashStockarch_dbt игнорируется
  )
    RETURN CLOB
  IS
    -- Константы
    C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := 'sofr_quik_money';
    C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Сверка_СОФР-QUIK_дс';
    C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := 'money_report';
    C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'GetMoneyReport';
    C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'Rest_info';

    -- Входной JSON
    C_IN_REPORT_DATE_TAG    CONSTANT VARCHAR2(32) := 'reportDate';
    C_IN_CLIENT_CODE_TAG    CONSTANT VARCHAR2(32) := 'clientCode';
    C_IN_CLIENT_NAME_TAG    CONSTANT VARCHAR2(32) := 'clientName';
    C_IN_CURR_CODE_TAG      CONSTANT VARCHAR2(32) := 'currency';
    C_IN_EXCLUDE_ZEROS_TAG  CONSTANT VARCHAR2(32) := 'excludeZeroBalances';
    C_IN_DATE_FORMAT        CONSTANT VARCHAR2(32) := 'YYYY-MM-DD';

    -- Константы - Ошибки
    C_ERR_02_CODE           CONSTANT VARCHAR2(8) := 'ER_02';
    C_ERR_02_MSG            CONSTANT VARCHAR2(64) := 'СОФР не смог сформировать отчет: клиент по ЕКК=''%s'' не найден';
    C_ERR_03_CODE           CONSTANT VARCHAR2(8) := 'ER_03';
    C_ERR_03_MSG            CONSTANT VARCHAR2(64) := 'СОФР не смог сформировать отчет: клиент по ФИО=''%s'' не найден';
    C_ERR_99_CODE           CONSTANT VARCHAR2(8) := 'ER_99';
    C_ERR_99_MSG            CONSTANT VARCHAR2(64) := 'СОФР не смог сформировать отчет: другая ошибка';

    -- Параметры входного запроса
    v_rd                    DATE; -- Формальная дата отчёта (для отображения пользователю и наименования отчёта)
    v_rd_fact               DATE; -- Фактическая дата, на которую формируется выборка (v_rd + 1), т.к. нас интересуют данные на конец указанного дня, а появляются они ночью следующего дня
    v_client_code           VARCHAR2(64); -- ЕКК клиента
    v_client_name           VARCHAR2(120); -- ФИО или часть ФИО клиента
    v_curr_code_list        SYS.ODCIVARCHAR2LIST; -- Массив с кодами валют
    v_exclude_zero_balances CHAR(1); -- Не выводить счета с нулевыми остатками: 1 - не выводить; 0 - выводить

    -- Переменные
    v_json_obj              JSON_OBJECT_T;
    v_has_args              BOOLEAN := FALSE;
    v_json_output           CLOB;

    -- Валидация
    v_is_ekk_exists         CHAR(1) := '0'; -- 1 - если ЕКК найден в СОФР или QUIK, иначе - 0
    v_is_fio_exists         CHAR(1) := '0'; -- 1 - если ФИО найден в СОФР, иначе - 0
    v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
  BEGIN
    it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Сверка остатков: СОФР-QUIK, Д/С', it_log.C_MSG_TYPE__DEBUG);

    -- Парсим входной JSON
    v_json_obj := JSON_OBJECT_T.parse(p_json_input);

    v_rd := TO_DATE(v_json_obj.get_string(C_IN_REPORT_DATE_TAG), C_IN_DATE_FORMAT);
    v_client_code := UPPER(v_json_obj.get_string(C_IN_CLIENT_CODE_TAG));
    v_client_name := UPPER(v_json_obj.get_string(C_IN_CLIENT_NAME_TAG));
    v_curr_code_list := GetArrayFromJsonField(p_json_input, C_IN_CURR_CODE_TAG);
    v_exclude_zero_balances := JsonBoolToNumber(v_json_obj.get_boolean(C_IN_EXCLUDE_ZEROS_TAG), 0);

    -- Если нет даты, отдаем мета-данные формы
    v_has_args := v_rd IS NOT NULL;
    IF NOT v_has_args THEN
      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Дата отчёта не указана, возвращаем Meta UI формы: Сверка остатков: СОФР-QUIK, Д/С', it_log.C_MSG_TYPE__DEBUG);
      RETURN BuildJsonOutput(p_body => GetMoneyReportMetaUI());
    END IF;

    IF (p_is_production = 0) THEN
        it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Парсинг входных параметров завершен', it_log.C_MSG_TYPE__DEBUG,
                   'Параметры отчёта: ' ||
                   'report_date=' || TO_CHAR(v_rd, 'YYYY-MM-DD') || ', ' ||
                   'client_code=' || COALESCE(v_client_code, 'NULL') || ', ' ||
                   'client_name=' || COALESCE(v_client_name, 'NULL') || ', ' ||
                   'exclude_zero_balances=' || COALESCE(v_exclude_zero_balances, 'NULL') || ', ' ||
                   'curr_code_list_count=' || CASE
                                                  WHEN v_curr_code_list IS NULL THEN '0'
                                                  ELSE TO_CHAR(v_curr_code_list.COUNT)
                                              END);
    END IF;

    v_rd_fact := v_rd + 1;

    -- Валидация входных параметров
    -- В СОФР или QUIK найдены счета с указанными ЕКК
    SELECT
      CASE
        WHEN v_client_code IS NULL OR v_client_code = '' THEN 1
        WHEN EXISTS (SELECT 1 FROM DDL_CLIENTINFO_DBT rest WHERE UPPER(rest.t_ekk) = v_client_code) THEN 1
        WHEN EXISTS (SELECT 1 FROM DDL_LIMITCASHSTOCK_DBT real WHERE UPPER(real.t_client_code) = v_client_code
                     UNION
                     SELECT 1 FROM DDL_LIMITCASHSTOCKARCH_DBT arch WHERE UPPER(arch.t_client_code) = v_client_code) THEN 1
        ELSE 0
      END
    INTO v_is_ekk_exists
    FROM dual;

    -- В СОФР существует клиент с введенным ФИО
    SELECT
      CASE
        WHEN v_client_name IS NULL OR v_client_name = '' THEN 1
        WHEN EXISTS (SELECT 1 FROM DPARTY_DBT cl WHERE UPPER(cl.t_name) LIKE '%' || v_client_name || '%') THEN 1
        ELSE 0
      END
    INTO v_is_fio_exists
    FROM dual;

    IF (v_is_ekk_exists = '0') THEN
      v_errors_array.append(GetErrorObjAndLog(p_trace_id_input,C_ERR_02_CODE,
                                              UTL_LMS.FORMAT_MESSAGE(C_ERR_02_MSG, v_client_code)));
    END IF;
    IF (v_is_fio_exists = '0') THEN
      v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_03_CODE,
                                              UTL_LMS.FORMAT_MESSAGE(C_ERR_03_MSG, v_client_name)));
    END IF;

    IF v_errors_array.get_size() > 0 THEN
        RAISE NO_DATA_FOUND;
    END IF;

    -- Генерация JSON отчёта
    WITH
      rest AS (
        SELECT rest1.t_accountid,
               rest1.t_restdate,
               rest1.t_restcurrency,
               rest1.t_rest
        FROM DRESTDATE_DBT rest1
          JOIN (SELECT t_accountid, t_restcurrency, max(t_restdate) t_restdate
                FROM DRESTDATE_DBT
                WHERE t_restdate <= v_rd_fact
                GROUP BY t_accountid, t_restcurrency) rest2
          ON rest1.t_accountid = rest2.t_accountid
            AND rest1.t_restcurrency = rest2.t_restcurrency
            AND rest1.t_restdate = rest2.t_restdate
      ),
      quik_real AS (
        SELECT q.*,
               CASE WHEN q.t_curr_code = 'SUR' THEN 'RUB' ELSE q.t_curr_code END cur,
               cl_q.t_name
        FROM DDL_LIMITCASHSTOCK_DBT q
          LEFT JOIN DPARTY_DBT cl_q ON cl_q.t_partyid = q.t_client -- ФИО клиента
        WHERE (p_is_production = 0 OR TRUNC(v_rd_fact) = TRUNC(sysdate)) -- только для актуальной даты
          AND q.t_date = v_rd_fact
          AND q.t_limit_kind = 0 -- T0 из QUIK
      ),
      quik_arch AS (
        SELECT q.*,
               CASE WHEN q.t_curr_code = 'SUR' THEN 'RUB' ELSE q.t_curr_code END cur,
               cl_q.t_name
        FROM DDL_LIMITCASHSTOCKARCH_DBT q
          LEFT JOIN dparty_dbt cl_q ON cl_q.t_partyid = q.t_client
        WHERE (p_is_production = 1 AND TRUNC(v_rd_fact) < TRUNC(sysdate)) -- только для исторической даты (всё, что старше сегодняшнего дня)
          AND q.t_date = v_rd_fact
          AND q.t_limit_kind = 0 -- T0 из QUIK
      ),
      quik AS (
        SELECT * FROM quik_real
        UNION ALL
        SELECT * FROM quik_arch
      ),
      ekk AS (SELECT DISTINCT t.t_ekk, t.t_partyid, t.t_accountid FROM DDL_CLIENTINFO_DBT t),
      result AS (
        SELECT quik.t_name AS T_CLIENT_NAME_Q, -- ФИО клиента из СОФР по ЕКК из QUIK
               cl.t_name AS T_CLIENT_NAME_S, -- ФИО клиента из СОФР
               quik.t_client_code AS T_CLIENT_CODE_Q, -- ЕКК из QUIK
               ekk.t_ekk AS T_CLIENT_CODE_S, -- ЕКК из СОФР
               quik.cur AS T_CURR_CODE_Q, -- Код валюты QUIK
               fin.t_ccy AS T_CURR_CODE_S, -- Код валюты СОФР
               DECODE(acc.t_daystoend, 0 , 'T0', 'T?') AS T_LIMIT_KIND, -- Период
               COALESCE(ROUND(quik.t_open_balance, 2), 0) AS T_AMOUNT_Q, -- Количество д/с из QUIK
               COALESCE(ROUND(rest.t_rest, 2), 0) AS T_AMOUNT_S -- Количество д/с из СОФР
        FROM daccount_dbt acc
          LEFT JOIN dparty_dbt cl ON cl.t_partyid = acc.t_client
          JOIN quik ON quik.t_internalaccount = acc.t_accountid
          LEFT JOIN rest
            ON acc.t_accountid = rest.t_accountid
            AND acc.t_code_currency = rest.t_restcurrency
          LEFT JOIN DFININSTR_DBT fin ON fin.t_fiid = acc.t_code_currency
          LEFT JOIN ekk
            ON ekk.t_partyid = cl.t_partyid
            AND ekk.t_accountid = acc.t_accountid
        WHERE 1=1
          AND acc.t_daystoend = 0 -- T0 из СОФР
          AND fin.t_fi_kind = 1 -- Тип инструмента д/с
          AND acc.t_Account LIKE '30601'|| fin.t_fi_code || '%'
          AND acc.t_type_account <> 'Ф?' -- идентификатор системного счета?  -- TODO убрать
          AND acc.t_open_close <> 'З'  -- открытый счет  -- TODO убрать
          AND (v_exclude_zero_balances = '0' OR (COALESCE(quik.t_open_balance, 0) <> 0 OR COALESCE(ROUND(rest.t_rest, 2), 0) <> 0)) -- Не выводить счета с нулевыми остатками: 1 - не выводить; 0 - выводить
          AND (NOT EXISTS (SELECT 1 FROM TABLE(v_curr_code_list))
               OR fin.t_ccy IN (SELECT COLUMN_VALUE FROM TABLE(v_curr_code_list)))
          AND (v_client_code IS NULL OR v_client_code = '' OR UPPER(ekk.t_ekk) = v_client_code)
          AND (v_client_name IS NULL OR v_client_name = '' OR UPPER(cl.t_name) LIKE '%'|| v_client_name || '%'))
    -- Строим напрямую через SQL JSON, а не PL/SQL JSON Object Types для экономии ресурсов
    SELECT (
      JSON_ARRAYAGG(
        JSON_OBJECT(
          'client_name_q' VALUE T_CLIENT_NAME_Q,
          'client_name_s' VALUE T_CLIENT_NAME_S,
          'client_code_q' VALUE T_CLIENT_CODE_Q,
          'client_code_s' VALUE T_CLIENT_CODE_S,
          'cur_type_q'    VALUE T_CURR_CODE_Q,
          'cur_type_s'    VALUE T_CURR_CODE_S,
          't_'            VALUE T_LIMIT_KIND,
          'amount_q'      VALUE T_AMOUNT_Q,
          'amount_s'      VALUE T_AMOUNT_S
        ) RETURNING CLOB
      )
    )
    INTO v_json_output
    FROM (
      SELECT r.*
      FROM result r
      UNION ALL
      -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
      SELECT NULL, NULL, NULL, NULL,
             NULL, NULL, NULL, NULL, NULL
      FROM dual
      WHERE NOT EXISTS (SELECT 1 FROM result)
    );

    v_json_output := BuildSplitJsonOutput(p_trace_id_input => p_trace_id_input,
                                          p_json_input => v_json_output,
                                          p_report_date_input => v_rd,
                                          p_report_tag => C_REPORT_NAME_TAG,
                                          p_items_arr_tag => C_ITEMS_ARR_TAG,
                                          p_template_name => C_TEMPLATE_NAME,
                                          p_output_file_name => C_OUTPUT_FILE_NAME,
                                          p_s3_file_name => C_S3_FILE_NAME);

    it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Построение отчёта успешно завершено: Сверка СОФР-QUIK по Д/С', it_log.C_MSG_TYPE__DEBUG);
    RETURN v_json_output;

    EXCEPTION
      WHEN OTHERS THEN
        -- Если массив ошибок пустой, но мы всё равно сюда попали, значит произошло что-то непредвиденное
        it_error.put_error_in_stack;
        IF (v_errors_array.get_size() = 0) THEN
          v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                  C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
        END IF;

        RETURN BuildJsonOutput(p_errors_array => v_errors_array);
  END Money_RC_ReportRun;

  -----------------------------------------------------------------------------
  ----- Формирование UI Form для Отчёта сравнения данных СОФР-QUIK по ц/б -----
  -----------------------------------------------------------------------------
  FUNCTION GetDepoReportMetaUI
    RETURN CLOB
  IS
    C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
    C_REPORT_LOCALIZED_NAME VARCHAR2(64)  := 'Сверка остатков: СОФР-QUIK, Ц/Б';
    C_SYS_TAGS              VARCHAR2(256) := '["ORACLE","QUIK"]';
    v_meta_ui               CLOB;
  BEGIN
    WITH
        quik_real AS (
            SELECT *
            FROM ddl_limitsecurites_dbt q
            WHERE q.t_limit_kind = 0 -- T0 из QUIK
        ),
        quik_arch AS (
            SELECT *
            FROM ddl_limitsecuritesarch_dbt q
            WHERE q.t_limit_kind = 0 -- T0 из QUIK
        ),
        quik AS (
            SELECT * FROM quik_real
            UNION
            SELECT * FROM quik_arch
        ),
        sectypes AS (
            SELECT DISTINCT
                CASE
                    WHEN quik.t_market_kind = 'валютный' -- [Костыль: USD000UTSTOM]
                        THEN 'Валюта'
                    ELSE q_fin_type.t_name
                END sectype
            FROM quik
                LEFT JOIN dobjcode_dbt obj ON quik.t_security = -1 AND quik.t_seccode = obj.t_code -- [Костыль: USD000UTSTOM]
                LEFT JOIN dfininstr_dbt q_fin -- Наименование бумаги для записей из QUIK
                          ON q_fin.t_fiid = quik.t_security
                              OR
                             (quik.t_security = -1 AND q_fin.t_fiid = obj.t_objectid) -- [Костыль: USD000UTSTOM]
                LEFT JOIN davrkinds_dbt q_fin_type -- Тип бумаги для записей из QUIK
                          ON q_fin.t_fi_kind = q_fin_type.t_fi_kind
                              AND q_fin.t_avoirkind = q_fin_type.t_avoirkind)
    SELECT
      JSON_OBJECT(
          C_META_UI_TAG__ROLES   VALUE C_ROLES FORMAT JSON,
          C_META_UI_TAG__LABEL   VALUE C_REPORT_LOCALIZED_NAME,
          C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
          C_META_UI_TAG__FORM    VALUE JSON_ARRAY(
              -- Первая строка
              JSON_ARRAY(
                  JSON_OBJECT(
                      'label'    VALUE 'Отчетная дата',
                      'name'     VALUE 'reportDate',
                      'type'     VALUE 'date',
                      'required' VALUE 'true' FORMAT JSON,
                      'column'   VALUE 0,
                      'default'  VALUE TO_CHAR(sysdate - 1, 'YYYY-MM-DD')
                      RETURNING CLOB
                  ),
                  JSON_OBJECT(
                      'label'    VALUE 'Эмитент',
                      'name'     VALUE 'issuer',
                      'type'     VALUE 'text',
                      'required' VALUE 'false' FORMAT JSON,
                      'column'   VALUE 1,
                      'default'  VALUE ''
                      RETURNING CLOB
                  )
              ),
              -- Вторая строка
              JSON_ARRAY(
                  JSON_OBJECT(
                      'label'    VALUE 'ЕКК клиента',
                      'name'     VALUE 'clientCode',
                      'type'     VALUE 'text',
                      'required' VALUE 'false' FORMAT JSON,
                      'column'   VALUE 0,
                      'default'  VALUE ''
                      RETURNING CLOB
                  ),
                  JSON_OBJECT(
                      'label'    VALUE 'Тип актива',
                      'name'     VALUE 'securityType',
                      'type'     VALUE 'select',
                      'required' VALUE 'true' FORMAT JSON,
                      'column'   VALUE 1,
                      'default'  VALUE (
                        SELECT JSON_ARRAYAGG(sectype RETURNING CLOB)
                        FROM secTypes
                      ),
                      'multiselect' VALUE 'true' FORMAT JSON,
                      'items'       VALUE (
                        SELECT JSON_ARRAYAGG(
                                   JSON_OBJECT(
                                       'name'  VALUE sectype,
                                       'value' VALUE sectype
                                   ) RETURNING CLOB
                               )
                        FROM secTypes
                      )
                      RETURNING CLOB
                  )
              ),
              -- Третья строка
              JSON_ARRAY(
                  JSON_OBJECT(
                      'label'    VALUE 'ФИО клиента',
                      'name'     VALUE 'clientName',
                      'type'     VALUE 'text',
                      'required' VALUE 'false' FORMAT JSON,
                      'column'   VALUE 0,
                      'default'  VALUE ''
                      RETURNING CLOB
                  ),
                  JSON_OBJECT(
                      'label'    VALUE 'Название актива',
                      'name'     VALUE 'securityName',
                      'type'     VALUE 'text',
                      'required' VALUE 'false' FORMAT JSON,
                      'column'   VALUE 1,
                      'default'  VALUE ''
                      RETURNING CLOB
                  )
              ),
              -- Четвёртая строка
              JSON_ARRAY(
                  JSON_OBJECT(
                      'label'    VALUE 'Не выводить счета с 0-ми остатками',
                      'name'     VALUE 'excludeZeroBalances',
                      'type'     VALUE 'checkBox',
                      'required' VALUE 'false' FORMAT JSON,
                      'column'   VALUE 0,
                      'default'  VALUE 'true' FORMAT JSON
                      RETURNING CLOB
                  )
              )
          ) RETURNING CLOB
      )
    INTO v_meta_ui
    FROM dual;

    RETURN v_meta_ui;
  END GetDepoReportMetaUI;

  -----------------------------------------------------------------
  ----- Формирование Отчёта сравнения данных СОФР-QUIK по Ц/Б -----
  -----------------------------------------------------------------
  FUNCTION Depo_RC_ReportRun(p_trace_id_input VARCHAR2,
                             p_json_input CLOB,
                             p_is_production CHAR DEFAULT '1' -- Флаг для режима прода:
                             -- Включает поиск в архивной таблице DDL_LIMITSECURITESARCH_DBT
                             --  1 - данные будут тянуться из DDL_LIMITSECURITES_DBT или DDL_LIMITSECURITESARCH_DBT в зависимости от даты
                             --  0 - данные будут тянуться из DDL_LIMITSECURITES_DBT, архивная таблица DDL_LIMITSECURITESARCH_DBT игнорируется
  )
    RETURN CLOB
  IS
    -- Константы
    C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := 'sofr_quik_depo';
    C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Сверка_СОФР-QUIK_цб';
    C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := 'depo_report';
    C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'GetDepoReport';
    C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'Rest_info';

    -- Входной JSON
    C_IN_REPORT_DATE_TAG    CONSTANT VARCHAR2(32) := 'reportDate';
    C_IN_CLIENT_CODE_TAG    CONSTANT VARCHAR2(32) := 'clientCode';
    C_IN_CLIENT_NAME_TAG    CONSTANT VARCHAR2(32) := 'clientName';
    C_IN_ISSUER_TAG         CONSTANT VARCHAR2(32) := 'issuer';
    C_IN_SECURITY_TYPE_TAG  CONSTANT VARCHAR2(32) := 'securityType';
    C_IN_SECURITY_NAME_TAG  CONSTANT VARCHAR2(32) := 'securityName';
    C_IN_EXCLUDE_ZEROS_TAG  CONSTANT VARCHAR2(32) := 'excludeZeroBalances';
    C_IN_DATE_FORMAT        CONSTANT VARCHAR2(32) := 'YYYY-MM-DD';

    -- Константы - Ошибки
    C_ERR_02_CODE           CONSTANT VARCHAR2(8) := 'ER_02';
    C_ERR_02_MSG            CONSTANT VARCHAR2(64) := 'СОФР не смог сформировать отчет: клиент по ЕКК=%s не найден';
    C_ERR_03_CODE           CONSTANT VARCHAR2(8) := 'ER_03';
    C_ERR_03_MSG            CONSTANT VARCHAR2(64) := 'СОФР не смог сформировать отчет: клиент по ФИО=%s не найден';
    C_ERR_04_CODE           CONSTANT VARCHAR2(8) := 'ER_04';
    C_ERR_04_MSG            CONSTANT VARCHAR2(64) := 'СОФР не смог сформировать отчет: эмитент сделки=%s не найден';
    C_ERR_05_CODE           CONSTANT VARCHAR2(8) := 'ER_05';
    C_ERR_05_MSG            CONSTANT VARCHAR2(64) := 'СОФР не смог сформировать отчет: название бумаги=%s не найдено';
    C_ERR_99_CODE           CONSTANT VARCHAR2(8) := 'ER_99';
    C_ERR_99_MSG            CONSTANT VARCHAR2(64) := 'СОФР не смог сформировать отчет: другая ошибка';

    -- Параметры входного запроса
    v_rd                    DATE; -- Формальная дата отчёта (для отображения пользователю и наименования отчёта)
    v_rd_fact               DATE; -- Фактическая дата, на которую формируется выборка (v_rd + 1), т.к. нас интересуют данные на конец указанного дня, а появляются они ночью следующего дня
    v_client_code           VARCHAR2(64); -- ЕКК клиента
    v_client_name           VARCHAR2(120); -- ФИО или часть ФИО клиента
    v_issuer                VARCHAR2(60); -- Эмитент бумаги
    v_sec_type_list         SYS.ODCIVARCHAR2LIST; -- Массив с Типами активов
    v_sec_name              VARCHAR2(50); -- Наименование бумаги
    v_exclude_zero_balances CHAR(1); -- Не выводить счета с нулевыми остатками: 1 - не выводить; 0 - выводить

    -- Переменные
    v_json_obj              JSON_OBJECT_T;
    v_has_args              BOOLEAN := FALSE;
    v_json_output           CLOB;

    -- Валидация
    v_is_ekk_exists         CHAR(1) := '0'; -- 1 - если ЕКК найден в СОФР или QUIK, иначе - 0
    v_is_fio_exists         CHAR(1) := '0'; -- 1 - если ФИО найден в СОФР, иначе - 0
    v_is_issuer_exists      CHAR(1) := '0'; -- 1 - если Эмитент найден в СОФР, иначе - 0
    v_is_security_exists    CHAR(1) := '0'; -- 1 - если Название бумаги найдено в СОФР, иначе - 0
    v_errors_array          JSON_ARRAY_T  := JSON_ARRAY_T();
  BEGIN
    it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Сверка остатков: СОФР-QUIK, Ц/Б', it_log.C_MSG_TYPE__DEBUG);

    -- Парсим входной JSON
    v_json_obj := JSON_OBJECT_T.parse(p_json_input);

    v_rd := TO_DATE(v_json_obj.get_string(C_IN_REPORT_DATE_TAG), C_IN_DATE_FORMAT);
    v_client_code := UPPER(v_json_obj.get_string(C_IN_CLIENT_CODE_TAG));
    v_client_name := UPPER(v_json_obj.get_string(C_IN_CLIENT_NAME_TAG));
    v_issuer := UPPER(v_json_obj.get_String(C_IN_ISSUER_TAG));
    v_sec_type_list := GetArrayFromJsonField(p_json_input, C_IN_SECURITY_TYPE_TAG);
    v_sec_name := UPPER(v_json_obj.get_String(C_IN_SECURITY_NAME_TAG));
    v_exclude_zero_balances := JsonBoolToNumber(v_json_obj.get_boolean(C_IN_EXCLUDE_ZEROS_TAG), 0);

    -- Если нет даты, отдаем мета-данные формы
    v_has_args := v_rd IS NOT NULL;
    IF NOT v_has_args THEN
      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Дата отчёта не указана, возвращаем Meta UI формы: Сверка остатков: СОФР-QUIK, Ц/Б', it_log.C_MSG_TYPE__DEBUG);
      RETURN BuildJsonOutput(p_body => GetDepoReportMetaUI());
    END IF;

    IF (p_is_production = 0) THEN
        it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Парсинг входных параметров завершен', it_log.C_MSG_TYPE__DEBUG,
                   'Параметры отчёта: ' ||
                   'report_date=' || TO_CHAR(v_rd, 'YYYY-MM-DD') || ', ' ||
                   'client_code=' || COALESCE(v_client_code, 'NULL') || ', ' ||
                   'client_name=' || COALESCE(v_client_name, 'NULL') || ', ' ||
                   'exclude_zero_balances=' || COALESCE(v_exclude_zero_balances, 'NULL') || ', ' ||
                   'issuer=' || COALESCE(v_issuer, 'NULL') || ', ' ||
                   'sec_name=' || COALESCE(v_sec_name, 'NULL') || ', ' ||
                   'sec_type_list_count=' || CASE
                                                  WHEN v_sec_type_list IS NULL THEN '0'
                                                  ELSE TO_CHAR(v_sec_type_list.COUNT)
                                              END);
    END IF;

    v_rd_fact := v_rd + 1;

    -- Валидация входных параметров
    -- В QUIK найдены счета с указанными ЕКК
    SELECT
      CASE
        WHEN v_client_code IS NULL OR v_client_code = '' THEN 1
        WHEN EXISTS (SELECT 1 FROM ddl_limitsecurites_dbt real WHERE UPPER(real.t_client_code) = v_client_code
                     UNION ALL
                     SELECT 1 FROM ddl_limitsecuritesarch_dbt arch WHERE UPPER(arch.t_client_code) = v_client_code) THEN 1
        ELSE 0
        END
    INTO v_is_ekk_exists
    FROM dual;

    -- В СОФР существует клиент с введенным ФИО
    SELECT
      CASE
        WHEN v_client_name IS NULL OR v_client_name = '' THEN 1
        WHEN EXISTS (SELECT 1 FROM dparty_dbt cl WHERE UPPER(cl.t_name) LIKE '%' || v_client_name || '%') THEN 1
        ELSE 0
        END
    INTO v_is_fio_exists
    FROM dual;

    -- В СОФР найден счет с указанным эмитентом
    SELECT
      CASE
        WHEN v_issuer IS NULL OR v_issuer = '' THEN 1
        WHEN EXISTS (SELECT 1 FROM dparty_dbt em WHERE UPPER(em.t_shortname) LIKE '%' || v_issuer || '%') THEN 1
        ELSE 0
        END
    INTO v_is_issuer_exists
    FROM dual;

    --  В СОФР найдена бумага с указанным наименованием
    SELECT
      CASE
        WHEN v_sec_name IS NULL OR v_sec_name = '' THEN 1
        WHEN EXISTS (SELECT 1 FROM dfininstr_dbt fin WHERE UPPER(fin.t_name) LIKE '%' || v_sec_name || '%') THEN 1
        ELSE 0
        END
    INTO v_is_security_exists
    FROM dual;

    IF (v_is_ekk_exists = '0') THEN
      v_errors_array.append(GetErrorObjAndLog(p_trace_id_input,C_ERR_02_CODE,
                                              UTL_LMS.FORMAT_MESSAGE(C_ERR_02_MSG, v_client_code)));
    END IF;
    IF (v_is_fio_exists = '0') THEN
      v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_03_CODE,
                                              UTL_LMS.FORMAT_MESSAGE(C_ERR_03_MSG, v_client_name)));
    END IF;
    IF (v_is_issuer_exists = '0') THEN
      v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_04_CODE,
                                              UTL_LMS.FORMAT_MESSAGE(C_ERR_04_MSG, v_issuer)));
    END IF;
    IF (v_is_security_exists = '0') THEN
      v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_05_CODE,
                                              UTL_LMS.FORMAT_MESSAGE(C_ERR_05_MSG, v_sec_name)));
    END IF;

    IF v_errors_array.get_size() > 0 THEN
      RAISE NO_DATA_FOUND;
    END IF;

    -- Генерация JSON отчёта
    WITH
      q_acc AS ( -- Для подвязки балансового счёта
          SELECT DISTINCT t_mpcode, t_currency, t_owner, t_marketid, t_account
          FROM ddlcontrmp_dbt contr
          LEFT JOIN (SELECT *
                     FROM dmcaccdoc_dbt mca
                     WHERE mca.t_activatedate <= v_rd -- Сравниваем с v_rd т.к. сделки совершались именно в v_rd, а в v_rd_fact произошла фиксация этих сделок в БД
                       AND (mca.t_disablingdate > v_rd OR
                            mca.t_disablingdate = TO_DATE('01010001', 'ddmmyyyy') -- Спец дата, если аккаунт действующий в настоящее время
                       )
                       AND mca.t_iscommon = 'X'
                       AND mca.t_account LIKE '61%') mca
                     ON contr.t_sfcontrid = mca.t_clientcontrid
          WHERE contr.t_mpregdate <= v_rd -- Сравниваем с v_rd т.к. сделки совершались именно в v_rd, а в v_rd_fact произошла фиксация этих сделок в БД
                      AND (contr.t_mpclosedate > v_rd OR
                           contr.t_mpclosedate = TO_DATE('01010001', 'ddmmyyyy') -- Спец дата, если клиент действующий в настоящее время
                      )
      ),
      zero_rest AS (SELECT DISTINCT t_codesczerolimit FROM ddl_limitprm_dbt), -- "Нулевые" лимиты
      rest AS ( -- Остатки на счетах
          SELECT rest1.t_accountid,
                 rest1.t_restdate,
                 rest1.t_restcurrency,
                 rest1.t_rest
          FROM drestdate_dbt rest1
                   JOIN (SELECT t_accountid, t_restcurrency, max(t_restdate) t_restdate
                         FROM drestdate_dbt
                         WHERE t_restdate <= v_rd_fact
                         GROUP BY t_accountid, t_restcurrency
                        ) rest2
                        ON rest1.t_accountid = rest2.t_accountid
                            AND rest1.t_restcurrency = rest2.t_restcurrency
                            AND rest1.t_restdate = rest2.t_restdate),
      quik_real AS (
          SELECT *
          FROM ddl_limitsecurites_dbt q
                   LEFT JOIN DPARTY_DBT cl_q ON cl_q.t_partyid = q.t_client -- ФИО клиента
          WHERE (p_is_production = 0 OR TRUNC(v_rd_fact) = TRUNC(sysdate)) -- только для актуальной даты
              AND q.t_limit_kind = 0 -- T0 из QUIK
              AND q.t_date = v_rd_fact
      ),
      quik_arch AS (
          SELECT *
          FROM ddl_limitsecuritesarch_dbt q
                   LEFT JOIN DPARTY_DBT cl_q ON cl_q.t_partyid = q.t_client -- ФИО клиента
          WHERE (p_is_production = 1 AND TRUNC(v_rd_fact) < TRUNC(sysdate)) -- -- только для исторической даты (всё, что старше сегодняшнего дня)
            AND q.t_limit_kind = 0 -- T0 из QUIK
            AND q.t_date = v_rd_fact
      ),
      quik AS (
          SELECT * FROM quik_real
          UNION ALL
          SELECT * FROM quik_arch
      ),
      result AS (
        SELECT quik.t_name                                       AS t_client_name_q,   -- ФИО клиента из СОФР по ЕКК из QUIK
               CASE
                   WHEN zero_rest.t_codesczerolimit IS NOT NULL
                       THEN COALESCE(quik.t_name, '-1')
                   ELSE cl.t_name
               END                                               AS t_client_name_s,   -- ФИО клиента из СОФР
               quik.t_client_code                                AS t_client_code_q,   -- ЕКК из QUIK
               CASE
                   WHEN quik.t_client = s_acc.t_client
                       THEN quik.t_client_code
                   ELSE '-1'
               END                                               AS t_client_code_s,   -- ЕКК из СОФР
               COALESCE(q_em.t_shortname, '-1')                  AS t_issuer_q,        -- Наименование эмитента
               CASE
                   WHEN zero_rest.t_codesczerolimit IS NOT NULL
                       THEN COALESCE(q_em.t_shortname, '-1')
                   ELSE em.t_shortname
               END                                               AS t_issuer_s,        -- Наименование эмитента
               CASE
                   WHEN quik.t_market_kind = 'валютный' -- [Костыль: USD000UTSTOM]
                       THEN 'Валюта'
                   ELSE COALESCE(q_fin_type.t_name, '-1')
               END                                               AS t_security_type_q, -- Вид финансового инструмента
               CASE
                   WHEN zero_rest.t_codesczerolimit IS NOT NULL
                       THEN CASE
                                WHEN quik.t_security = -1 -- [Костыль: USD000UTSTOM]
                                    THEN 'Валюта'
                                ELSE COALESCE(q_fin_type.t_name, '-1')
                            END
                   ELSE fin_type.t_name
               END                                               AS t_security_type_s, -- Вид финансового инструмента
               COALESCE(q_fin.t_name, '-1')                      AS t_security_name_q, -- Название финансового инструмента
               CASE
                   WHEN zero_rest.t_codesczerolimit IS NOT NULL
                       THEN COALESCE(q_fin.t_name, '-1')
                   ELSE fin.t_name
               END                                               AS t_security_name_s, -- Название финансового инструмента
               COALESCE(quik.t_open_balance, -1)                 AS t_amount_q,        -- Остаток ц/б на счете клиента
               CASE
                   WHEN zero_rest.t_codesczerolimit IS NOT NULL
                       THEN 0
                   ELSE rest.t_rest
               END                                               AS t_amount_s,         -- Остаток ц/б на счете клиента
               decode(quik.t_limit_kind, 0 , 'T0', 'T?')         AS t_limit_kind        -- Режим сделки, рассматривается только Т0
        FROM quik
            LEFT JOIN q_acc -- Для подвязки балансового счёта
              ON quik.t_client_code = q_acc.t_mpcode
                AND quik.t_market = q_acc.t_marketid
                AND q_acc.t_currency = quik.t_security
                AND q_acc.t_owner = quik.t_client
            -- [Костыль: USD000UTSTOM] В записях QUIK'а по ц/б по неопределённой причине присутствует валюта t_seccode="USD000UTSTOM", данный join исключительно, чтоб обработать эту дефектную запись
            LEFT JOIN dobjcode_dbt obj ON quik.t_security = -1 AND quik.t_seccode = obj.t_code -- [Костыль: USD000UTSTOM] Джоиним код объекта валюты
            LEFT JOIN dfininstr_dbt q_fin -- Наименование бумаги для записей из QUIK
                      ON q_fin.t_fiid = quik.t_security
                          OR (quik.t_security = -1 AND q_fin.t_fiid = obj.t_objectid) -- [Костыль: USD000UTSTOM]
            LEFT JOIN davrkinds_dbt q_fin_type -- Тип бумаги для записей из QUIK
                      ON q_fin.t_fi_kind = q_fin_type.t_fi_kind
                          AND q_fin.t_avoirkind = q_fin_type.t_avoirkind
            LEFT JOIN dparty_dbt q_em -- Эмитент для записей из QUIK
                      ON q_em.t_partyid = q_fin.t_issuer
            LEFT JOIN zero_rest -- "Нулевые" лимиты
                      ON zero_rest.t_codesczerolimit = quik.t_seccode
            LEFT JOIN daccount_dbt s_acc -- Балансовый счет СОФР, нужен, чтобы подтянуть остаток по счету
                      ON s_acc.t_account = q_acc.t_account
                          AND s_acc.t_code_currency = quik.t_security
            LEFT JOIN rest -- Остатки на счетах
                      ON s_acc.t_accountid = rest.t_accountid
            LEFT JOIN dparty_dbt cl -- ФИО клиента
                      ON cl.t_partyid = s_acc.t_client
            LEFT JOIN dfininstr_dbt fin -- Наименование валюты
                      ON fin.t_fiid = s_acc.t_code_currency
            LEFT JOIN davrkinds_dbt fin_type -- Тип бумаги
                      ON fin.t_fi_kind = fin_type.t_fi_kind
                          AND fin.t_avoirkind = fin_type.t_avoirkind
            LEFT JOIN dparty_dbt em -- Эмитент
                      ON em.t_partyid = fin.t_issuer
        WHERE 1=1
          AND (v_exclude_zero_balances = '0' OR (COALESCE(quik.t_open_balance, -1) <> 0 OR (zero_rest.t_codesczerolimit IS NULL AND rest.t_rest <> 0))) -- Не выводить счета с нулевыми остатками: 1 - не выводить; 0 - выводить
          AND (NOT EXISTS (SELECT 1 FROM TABLE(v_sec_type_list))
            OR CASE
                   WHEN quik.t_market_kind = 'валютный' -- [Костыль: USD000UTSTOM]
                       THEN 'Валюта'
                   ELSE q_fin_type.t_name
               END IN (SELECT COLUMN_VALUE FROM TABLE(v_sec_type_list)))
          AND (v_client_code IS NULL OR v_client_code = '' OR UPPER(quik.t_client_code) = v_client_code)
          AND (v_client_name IS NULL OR v_client_name = '' OR UPPER(quik.t_name) LIKE '%'|| v_client_name || '%')
          AND (v_sec_name IS NULL OR v_sec_name = '' OR UPPER(q_fin.t_name) LIKE '%'|| v_sec_name || '%'))
    -- Строим напрямую через SQL JSON, а не PL/SQL JSON Object Types для экономии ресурсов
    SELECT (
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'client_name_q' VALUE t_client_name_q,
                'client_name_s' VALUE t_client_name_s,
                'client_code_q' VALUE t_client_code_q,
                'client_code_s' VALUE t_client_code_s,
                'emi_q'         VALUE t_issuer_q,
                'emi_s'         VALUE t_issuer_s,
                'sec_type_q'    VALUE t_security_type_q,
                'sec_type_s'    VALUE t_security_type_s,
                'sec_name_q'    VALUE t_security_name_q,
                'sec_name_s'    VALUE t_security_name_s,
                't_'            VALUE t_limit_kind,
                'amount_q'      VALUE t_amount_q,
                'amount_s'      VALUE t_amount_s
            ) RETURNING CLOB
        )
    )
    INTO v_json_output
    FROM (
        SELECT r.*
        FROM result r
        UNION ALL
        -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
        SELECT NULL, NULL, NULL, NULL,
               NULL, NULL, NULL, NULL,
               NULL,NULL,NULL,NULL,NULL
        FROM dual
        WHERE NOT EXISTS (SELECT 1 FROM result)
    );

    v_json_output := BuildSplitJsonOutput(p_trace_id_input => p_trace_id_input,
                                          p_json_input => v_json_output,
                                          p_report_date_input => v_rd,
                                          p_report_tag => C_REPORT_NAME_TAG,
                                          p_items_arr_tag => C_ITEMS_ARR_TAG,
                                          p_template_name => C_TEMPLATE_NAME,
                                          p_output_file_name => C_OUTPUT_FILE_NAME,
                                          p_s3_file_name => C_S3_FILE_NAME);

    it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Построение отчёта успешно завершено: Сверка остатков: СОФР-QUIK, Ц/Б', it_log.C_MSG_TYPE__DEBUG);

    RETURN v_json_output;

    EXCEPTION
      WHEN OTHERS THEN
        -- Если массив ошибок пустой, но мы всё равно сюда попали, значит произошло что-то непредвиденное
        it_error.put_error_in_stack;
        IF (v_errors_array.get_size() = 0) THEN
          v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                  C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
        END IF;

        RETURN BuildJsonOutput(p_errors_array => v_errors_array);
  END Depo_RC_ReportRun;

  -----------------------------------------------------------------------------
  ----- Формирование UI Form для Отчёта сравнения данных СОФР-QUIK, Д/С и Ц/Б-----
  -----------------------------------------------------------------------------
  FUNCTION GetMoneyDepoReportMetaUI
      RETURN CLOB
  IS
      C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
      C_REPORT_LOCALIZED_NAME VARCHAR2(64)  := 'Сверка остатков: СОФР-QUIK, Д/С и Ц/Б';
      C_SYS_TAGS              VARCHAR2(256) := '["ORACLE","QUIK"]';
      v_meta_ui               CLOB;
  BEGIN
      SELECT
          JSON_OBJECT(
              C_META_UI_TAG__ROLES   VALUE C_ROLES FORMAT JSON,
              C_META_UI_TAG__LABEL   VALUE C_REPORT_LOCALIZED_NAME,
              C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
              C_META_UI_TAG__FORM    VALUE JSON_ARRAY(
                  -- Первая строка
                  JSON_ARRAY(
                      JSON_OBJECT(
                          'label'    VALUE 'Отчетная дата',
                          'name'     VALUE 'reportDate',
                          'type'     VALUE 'date',
                          'required' VALUE 'true' FORMAT JSON,
                          'column'   VALUE 0,
                          'default'  VALUE TO_CHAR(sysdate - 1, 'YYYY-MM-DD')
                          RETURNING CLOB
                      ),
                      JSON_OBJECT(
                          'label'    VALUE 'ЕКК клиента',
                          'name'     VALUE 'clientCode',
                          'type'     VALUE 'text',
                          'required' VALUE 'false' FORMAT JSON,
                          'column'   VALUE 1,
                          'default'  VALUE ''
                          RETURNING CLOB
                      )
                  ),
                  -- Вторая строка
                  JSON_ARRAY(
                      JSON_OBJECT(
                          'label'    VALUE 'Не выводить счета с 0-ми остатками',
                          'name'     VALUE 'excludeZeroBalances',
                          'type'     VALUE 'checkBox',
                          'required' VALUE 'false' FORMAT JSON,
                          'column'   VALUE 0,
                          'default'  VALUE 'true' FORMAT JSON
                          RETURNING CLOB
                      ),
                      JSON_OBJECT(
                          'label'    VALUE 'ФИО клиента',
                          'name'     VALUE 'clientName',
                          'type'     VALUE 'text',
                          'required' VALUE 'false' FORMAT JSON,
                          'column'   VALUE 1,
                          'default'  VALUE ''
                          RETURNING CLOB
                      )
                  )
              ) RETURNING CLOB
          )
      INTO v_meta_ui
      FROM dual;

      RETURN v_meta_ui;
  END GetMoneyDepoReportMetaUI;

  -------------------------------------------------------------------------------
  ----- Формирование Отчёта сравнения данных СОФР-QUIK по всем инструментам -----
  -------------------------------------------------------------------------------
  FUNCTION MoneyDepo_RC_ReportRun(p_trace_id_input VARCHAR2,
                                  p_json_input CLOB,
                                  p_is_production CHAR DEFAULT '1' -- Флаг для режима прода:
                                  -- Включает поиск в архивных таблицах DDL_LIMITCASHSTOCKARCH_DBT и DDL_LIMITSECURITESARCH_DBT
                                  --  1 - данные будут тянуться из основных (DDL_LIMITCASHSTOCK_DBT и DDL_LIMITSECURITES_DBT)
                                  --  или архивных (DDL_LIMITCASHSTOCKARCH_DBT и DDL_LIMITSECURITESARCH_DBT) таблиц в зависимости от даты
                                  --  0 - данные будут тянуться из основных таблиц, архивные таблицы игнорируется
  )
    RETURN CLOB
  IS
    -- Константы - Входной JSON
    C_IN_REPORT_DATE_TAG    CONSTANT VARCHAR2(32) := 'reportDate';
    C_IN_DATE_FORMAT        CONSTANT VARCHAR2(32) := 'YYYY-MM-DD';

    -- Константы - Ошибки
    C_ERR_99_CODE           CONSTANT VARCHAR2(8) := 'ER_99';
    C_ERR_99_MSG            CONSTANT VARCHAR2(64) := 'СОФР не смог сформировать отчет: другая ошибка';

    -- Переменные
    v_money_report CLOB;
    v_depo_report  CLOB;
    v_money_length INTEGER;
    v_depo_length  INTEGER;
    v_dest_offset  INTEGER;
    v_json_obj     JSON_OBJECT_T;
    v_rd           DATE;
    v_has_args     BOOLEAN := FALSE;
    v_errors_array JSON_ARRAY_T := JSON_ARRAY_T();

    v_json_output   CLOB;
  BEGIN
    it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Сверка остатков: СОФР-QUIK, Д/С и Ц/Б', it_log.C_MSG_TYPE__DEBUG);

    -- Парсим входной JSON
    v_json_obj := JSON_OBJECT_T.parse(p_json_input);
    v_rd := TO_DATE(v_json_obj.get_string(C_IN_REPORT_DATE_TAG), C_IN_DATE_FORMAT);

    -- Если нет даты, отдаем мета-данные формы
    v_has_args := v_rd IS NOT NULL;
    IF NOT v_has_args THEN
      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Дата отчёта не указана, возвращаем Meta UI формы: Сверка остатков: СОФР-QUIK, Д/С и Ц/Б', it_log.C_MSG_TYPE__DEBUG);
      RETURN BuildJsonOutput(p_body => GetMoneyDepoReportMetaUI());
    END IF;

    DBMS_LOB.CREATETEMPORARY(v_json_output, FALSE);
    v_money_report := Money_RC_ReportRun(p_trace_id_input, p_json_input, p_is_production);
    v_depo_report := Depo_RC_ReportRun(p_trace_id_input, p_json_input, p_is_production);

    v_money_length := DBMS_LOB.GETLENGTH(v_money_report);
    v_depo_length := DBMS_LOB.GETLENGTH(v_depo_report);

    -- Копируем MoneyReport без последней скобки ']'
    DBMS_LOB.COPY(v_json_output, v_money_report, v_money_length - 1, 1, 1);

    -- Добавляем запятую
    DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');

    v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
    -- Копируем DepoReport без первой '['
    DBMS_LOB.COPY(v_json_output, v_depo_report, v_depo_length - 1, v_dest_offset, 2);

    it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Построение отчёта успешно завершено: Сверка остатков: СОФР-QUIK, Д/С и Ц/Б', it_log.C_MSG_TYPE__DEBUG);
    RETURN v_json_output;

  EXCEPTION
      WHEN OTHERS THEN
          -- Освобождаем ресурсы
          IF DBMS_LOB.ISTEMPORARY(v_json_output) = 1 THEN
              DBMS_LOB.FREETEMPORARY(v_json_output);
          END IF;

          -- Если мы сюда попали, значит произошло что-то непредвиденное
          it_error.put_error_in_stack;
          IF (v_errors_array.get_size() = 0) THEN
              v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                      C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
          END IF;

          RETURN BuildJsonOutput(p_errors_array => v_errors_array);
  END MoneyDepo_RC_ReportRun;

  /**************************************************************************************************\
  [Конец блока] BIQ-23781.1(intech), BIQ-29457.1(avt) Расхождениях параметров сделок в СОФР с параметрами из биржевых файлов
  \**************************************************************************************************/


  /************************************************************************************************************\
  [Начало блока] BIQ-23781.1(intech), BIQ-29457.1(avt) Расхождениях параметров сделок в СОФР с параметрами из биржевых файлов
  **************************************************************************************************************
  Изменения:
  --------------------------------------------------------------------------------------------------------------
  Дата        Автор            Jira                                    Описание
  ----------  ---------------  --------------------------------------  -----------------------------------------
  26.08.2025  Логинов Н.А.     BIQ-23781.1(intech), BIQ-29457.1(avt)   Создание
  \*************************************************************************************************************/
  FUNCTION ParseMarketFiles(p_trace_id_input   VARCHAR2,
                            p_json_input       CLOB,
                            p_market_file_type VARCHAR2,
                            p_array_path       VARCHAR2) -- путь к массиву, например '$.marketFilesStocks.files[*]'
    RETURN INTEGER
  IS
    PRAGMA AUTONOMOUS_TRANSACTION;

    v_sql    VARCHAR2(1028);
    v_item   CLOB;
    cnt      INTEGER := 0;
    v_cursor SYS_REFCURSOR;
  BEGIN
    -- Динамический SQL с JSON_TABLE
    v_sql :=
        'SELECT jt.file_clob ' ||
        'FROM JSON_TABLE(:json, ''' || CASE
                                         WHEN p_array_path LIKE '%[*]'
                                           THEN p_array_path
                                         ELSE p_array_path || '[*]'
                                       END || ''' ' ||
        '         COLUMNS (file_clob CLOB PATH ''$'') ' ||
        ') jt';

    -- Открываем курсор
    OPEN v_cursor FOR v_sql USING p_json_input;
    LOOP
      FETCH v_cursor INTO v_item;
      EXIT WHEN v_cursor%NOTFOUND;

      CASE p_market_file_type
        WHEN C_MARKET_FILE_TAG__STOCKS THEN
          cnt := cnt + ParseSEM03(p_trace_id_input, v_item);
        WHEN C_MARKET_FILE_TAG__FOREX THEN
          cnt := cnt + ParseCUX23(p_trace_id_input, v_item);
        WHEN C_MARKET_FILE_TAG__FUTURES THEN
          cnt := cnt + ParseF04O04(p_trace_id_input, v_item, 'F');
        WHEN C_MARKET_FILE_TAG__OPTIONS THEN
          cnt := cnt + ParseF04O04(p_trace_id_input, v_item, 'O');
        ELSE
          RAISE_APPLICATION_ERROR(-20001, 'Неизвестный парсер: ' || p_market_file_type);
        END CASE;

    END LOOP;

    CLOSE v_cursor;
    COMMIT;

    RETURN cnt;
  END ParseMarketFiles;

  -------------------------------------------------------------------------------------------------------------
  ----- Проверяет объект биржевых файлов на наличие ошибки для errors_array, если есть, возвращает объект с сообщением ошибки, иначе NULL -----
  -------------------------------------------------------------------------------------------------------------
  FUNCTION GetMarketFileErrObj(
    p_trace_id_input    VARCHAR2,
    p_report_date_input DATE,
    p_dir_date_format   VARCHAR2,
    p_market_files_obj  JSON_OBJECT_T

  ) RETURN JSON_OBJECT_T IS
    -- Константы - Ошибки
    C_ERR_02_1_CODE         CONSTANT VARCHAR2(8)   := 'ER_02.1';
    C_ERR_02_1_MSG          CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: на указанную дату нет биржевого(ых) файла(ов): ''%s'', вероятно, файл(ы) был(и) перемещён(ы)';
    C_ERR_02_2_CODE         CONSTANT VARCHAR2(8)   := 'ER_02.2';
    C_ERR_02_2_MSG          CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: на указанную дату не найдено биржевых файлов в директории: ''%s''';

    v_files_err_obj JSON_OBJECT_T; -- Объект ошибки получения Биржевых файлов
  BEGIN
    IF p_market_files_obj IS NULL THEN
      RAISE_APPLICATION_ERROR(-20001, 'Неверный запрос: отсутствует массив биржевых файлов');
    END IF;

    IF p_market_files_obj.HAS(C_MARKET_FILE_TAG__ERROR) THEN
      v_files_err_obj := p_market_files_obj.get_object(C_MARKET_FILE_TAG__ERROR);
      IF v_files_err_obj.HAS(C_MARKET_FILE_TAG__SEARCH_PATH) THEN -- Файла был в индексе шары, но его куда-то унесли/удалили
        RETURN GetErrorObjAndLog(p_trace_id_input, C_ERR_02_1_CODE,
                                                UTL_LMS.FORMAT_MESSAGE(C_ERR_02_1_MSG, v_files_err_obj.get_string(C_MARKET_FILE_TAG__SEARCH_PATH)));
      ELSIF v_files_err_obj.HAS(C_MARKET_FILE_TAG__SHARE_PATH) THEN -- Не найдено ни одного файла за указанную дату
        RETURN GetErrorObjAndLog(p_trace_id_input, C_ERR_02_2_CODE,
                                                UTL_LMS.FORMAT_MESSAGE(C_ERR_02_2_MSG, v_files_err_obj.get_string(C_MARKET_FILE_TAG__SHARE_PATH) || TO_CHAR(p_report_date_input, p_dir_date_format)));
      END IF;
    END IF;
    RETURN NULL;
  END GetMarketFileErrObj;

  -------------------------------------------------------------------------------------------------------------
  ----- Парсинг биржевого файла Sem03 (для сделок на фондовом рынке) во временную таблицу DBDUI_SEM03_FILE_DBT -----
  ----- RETURN число строк, вставленных во временную таблицу -----
  -------------------------------------------------------------------------------------------------------------
  FUNCTION ParseSEM03(p_trace_id_input VARCHAR2, p_xml CLOB)
    RETURN INTEGER
  IS
  BEGIN
    -- Сообщение стоит включать исключительно для отладки, дабы не грузить базу сохранением лишних CLOB'ов
--     it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Получен биржевой файл фондового рынка, парсинг запущен', it_log.C_MSG_TYPE__DEBUG, p_xml);
    it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Получен биржевой файл фондового рынка, парсинг запущен', it_log.C_MSG_TYPE__DEBUG);

    INSERT INTO dbdui_sem03_file_dbt (
      T_CODE_M,
      T_SOFR_DEALCODE,
      T_DATE_M,
      T_TIME_M,
      T_DATE_CLR_M,
      T_CLIENT_CODE_M,
      T_DETAILS_M,
      T_OPER_M,
      T_QUANTITY_M,
      T_AMOUNT_M,
      T_ISIN_M,
      T_SECNAME_M
    )
    WITH
      parsed_xml AS (
        SELECT
          UPPER(T_CODE)                             AS T_CODE_M,
          UPPER(rec.T_OPER) || '/' || UPPER(T_CODE) AS T_SOFR_DEALCODE,
          TO_DATE(T_DATE, 'YYYY-MM-DD')             AS T_DATE_M,
          TO_TIMESTAMP(T_DATE || ' ' || T_TIME,
                       'YYYY-MM-DD HH24:MI:SS')     AS T_TIME_M,
          TO_DATE(T_DATE_CLR, 'YYYY-MM-DD')         AS T_DATE_CLR_M,
          UPPER(T_CLIENT_CODE)                      AS T_CLIENT_CODE_M,
          T_DETAILS                                 AS T_DETAILS_M,
          rec.T_OPER                                AS T_OPER_M,
          ToLocalNumber(T_QUANTITY)                 AS T_QUANTITY_M,
          ToLocalNumber(T_AMOUNT)                   AS T_AMOUNT_M,
          T_ISIN                                    AS T_ISIN_M,
          T_SECNAME                                 AS T_SECNAME_M
        FROM
          XMLTABLE(
              '/MICEX_DOC/SEM03'
              PASSING XMLTYPE(p_xml)
              COLUMNS
                T_DATE         VARCHAR2(20)  PATH '@TradeDate',
                sem_xml        XMLTYPE       PATH '.'
          ) AS sem03,
          XMLTABLE(
              '//SESSION/FIRM/CURRENCY/BOARD/SETTLEDATE'
              PASSING sem03.sem_xml
              COLUMNS
                T_DATE_CLR     VARCHAR2(35)  PATH '@SettleDate',
                settle_xml     XMLTYPE       PATH '.'
          ) AS settle,
          XMLTABLE(
              '//SECURITY'
              PASSING settle.settle_xml
              COLUMNS
                T_ISIN        VARCHAR2(35)   PATH '@SecurityId',
                T_SECNAME     VARCHAR2(200)  PATH '@SecName',
                sec_xml       XMLTYPE        PATH '.'
          ) sec,
          XMLTABLE(
              '//TRDACC'
              PASSING sec.sec_xml
              COLUMNS
                TRDACCID      VARCHAR2(35)   PATH '@TrdAccId',
                trdacc_xml    XMLTYPE        PATH '.'
          ) trdacc,
          XMLTABLE(
              '//TRDACC/RECORDS'
              PASSING trdacc.trdacc_xml
              COLUMNS
                T_CODE        VARCHAR2(30)   PATH '@TradeNo',
                T_TIME        VARCHAR2(20)   PATH '@TradeTime',
                T_CLIENT_CODE VARCHAR2(64)   PATH '@ClientCode',
                T_DETAILS     VARCHAR2(64)   PATH 'translate(@Details, " ", "")',
                T_OPER        VARCHAR2(79)   PATH '@BuySell',
                T_QUANTITY    VARCHAR2(64)   PATH '@Quantity' DEFAULT 0,
                T_AMOUNT      VARCHAR2(64)   PATH '@Amount'   DEFAULT 0
          ) rec
        WHERE UPPER(SUBSTR(TRDACCID, 1, 1)) NOT IN ('S', 'A') -- Если TrdAccId начинается на "S..." или "A..." - это признак собственной сделки Банка, такие сделки в отчет не должны попадать
      )
    SELECT *
    FROM parsed_xml;
    it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Парсинг завершен, получено строк: ' || SQL%ROWCOUNT, it_log.C_MSG_TYPE__DEBUG);
    RETURN SQL%ROWCOUNT;
  EXCEPTION
    WHEN OTHERS THEN
      it_error.put_error_in_stack;
      RAISE_APPLICATION_ERROR(-20001, 'traceId=''' || p_trace_id_input || ''' ' || 'Ошибка парсинга XML: ' || SQLERRM);
  END ParseSEM03;

  FUNCTION AddCamelToExMetaArr(
    p_exmeta_arr   IN OUT NOCOPY JSON_ARRAY_T,
    p_route_id     VARCHAR2,
    p_camel_script CLOB
  )
    RETURN JSON_ARRAY_T
  IS
    v_camel_obj   JSON_OBJECT_T := JSON_OBJECT_T();
    v_exmeta_item JSON_OBJECT_T := JSON_OBJECT_T();
  BEGIN
    v_camel_obj.put('script', p_camel_script);
    v_camel_obj.put('routeId', p_route_id);
    v_camel_obj.put('routeUri', 'direct:' || p_route_id);

    v_exmeta_item.put('camel', v_camel_obj);
    p_exmeta_arr.append(v_exmeta_item);

    RETURN p_exmeta_arr;
  END AddCamelToExMetaArr;

  ------------------------------------------------------------------------------------------------------
  ----- Формирование UI Form для Отчёта сравнения данных СОФР-Биржа, Фондовый рынок -----
  ------------------------------------------------------------------------------------------------------
  FUNCTION StockMarketReportMetaUI
    RETURN CLOB
  IS
    C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
    C_REPORT_LOCALIZED_NAME VARCHAR2(128) := 'Сверка сделок: СОФР-Биржа, Фондовый рынок';
    C_SYS_TAGS              VARCHAR2(256) := '["ORACLE","Exchange"]';
    v_meta_ui               CLOB;
  BEGIN
    WITH deal_types(name, value) AS (
      SELECT 'Покупка', 'B' FROM dual
      UNION ALL
      SELECT 'Продажа', 'S' FROM dual
    )
    SELECT
      JSON_OBJECT(
          C_META_UI_TAG__ROLES   VALUE C_ROLES FORMAT JSON,
          C_META_UI_TAG__LABEL   VALUE C_REPORT_LOCALIZED_NAME,
          C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
          C_META_UI_TAG__FORM    VALUE JSON_ARRAY(
            -- Первая строка
              JSON_ARRAY(
                  JSON_OBJECT(
                      'label'    VALUE 'Дата сделки',
                      'name'     VALUE 'reportDate',
                      'type'     VALUE 'date',
                      'required' VALUE 'true' FORMAT JSON,
                      'column'   VALUE 0,
                      'default'  VALUE TO_CHAR(sysdate, 'YYYY-MM-DD')
                      RETURNING CLOB
                  ),
                  JSON_OBJECT(
                      'label'    VALUE 'ЕКК клиента',
                      'name'     VALUE 'clientCode',
                      'type'     VALUE 'text',
                      'required' VALUE 'false' FORMAT JSON,
                      'column'   VALUE 1,
                      'default'  VALUE ''
                      RETURNING CLOB
                  ),
                  JSON_OBJECT(
                      'label'    VALUE 'Направление сделки',
                      'name'     VALUE 'dealType',
                      'type'     VALUE 'select',
                      'required' VALUE 'true' FORMAT JSON,
                      'column'   VALUE 2,
                      'default'  VALUE (
                        SELECT JSON_ARRAYAGG(VALUE RETURNING CLOB)
                        FROM deal_types
                      ),
                      'multiselect' VALUE 'true' FORMAT JSON,
                      'items'       VALUE (
                        SELECT JSON_ARRAYAGG(
                                   JSON_OBJECT(
                                       'name'  VALUE name,
                                       'value' VALUE VALUE
                                   ) RETURNING CLOB
                               )
                        FROM deal_types
                      )
                      RETURNING CLOB
                  )
              ),
              -- Вторая строка
              JSON_ARRAY(
                  JSON_OBJECT(
                      'label'    VALUE 'Номер сделки',
                      'name'     VALUE 'dealNum',
                      'type'     VALUE 'text',
                      'required' VALUE 'false' FORMAT JSON,
                      'column'   VALUE 0,
                      'default'  VALUE ''
                      RETURNING CLOB
                  ),
                  JSON_OBJECT(
                      'label'    VALUE 'ФИО клиента',
                      'name'     VALUE 'clientName',
                      'type'     VALUE 'text',
                      'required' VALUE 'false' FORMAT JSON,
                      'column'   VALUE 1,
                      'default'  VALUE ''
                      RETURNING CLOB
                  ),
                  JSON_OBJECT(
                      'label'    VALUE 'Тикер бумаги',
                      'name'     VALUE 'ticker',
                      'type'     VALUE 'text',
                      'required' VALUE 'false' FORMAT JSON,
                      'column'   VALUE 2,
                      'default'  VALUE ''
                      RETURNING CLOB
                  )
              )
          ) RETURNING CLOB
      )
    INTO v_meta_ui
    FROM dual;

    RETURN v_meta_ui;
  END StockMarketReportMetaUI;

  FUNCTION ClearTmpSem03
    RETURN INTEGER
  IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    DELETE FROM dbdui_sem03_file_dbt;
    COMMIT;
    RETURN 1;
  END;

  ------------------------------------------------------------------------------------------
  ----- Формирование Отчёта сравнения данных СОФР-Биржа, Фондовый рынок -----
  ------------------------------------------------------------------------------------------
  FUNCTION StockMarket_RC_ReportRun(p_trace_id_input VARCHAR2,
                                    p_json_input CLOB,
                                    p_is_production CHAR DEFAULT '1' -- Флаг для режима прода:
                                    -- Включает режим продакшн
                                    --  1 - выборка клиента будет происходить в соответствии с паспортными данными клиента
                                    --  0 - паспортные данные игнорируются при выборке клиента (т.к. данные обезличены, а в паспорте рандомные цифры)
  )
    RETURN CLOB
  IS
    -- Константы
    C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := 'sofr_market_sem03';
    C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Сверка_СОФР-биржа_фондовый_рынок';
    C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := 'stockmarket_report';
    C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'GetStockMarket';
    C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'deals';

    -- Входной JSON
    C_IN_REPORT_DATE_TAG    CONSTANT VARCHAR2(32) := 'reportDate';
    C_IN_CLIENT_CODE_TAG    CONSTANT VARCHAR2(32) := 'clientCode';
    C_IN_CLIENT_NAME_TAG    CONSTANT VARCHAR2(32) := 'clientName';
    C_IN_DEAL_TYPE_TAG      CONSTANT VARCHAR2(32) := 'dealType';
    C_IN_DEAL_NUM_TAG       CONSTANT VARCHAR2(32) := 'dealNum';
    C_IN_TICKER_TAG         CONSTANT VARCHAR2(32) := 'ticker';
    C_IN_DATE_FORMAT        CONSTANT VARCHAR2(32) := 'YYYY-MM-DD';

    -- Константы - Ошибки
    C_ERR_03_CODE           CONSTANT VARCHAR2(8)   := 'ER_03';
    C_ERR_03_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: клиент по ЕКК=''%s'' не найден';
    C_ERR_04_CODE           CONSTANT VARCHAR2(8)   := 'ER_04';
    C_ERR_04_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: клиент по ФИО=''%s'' не найден';
    C_ERR_05_CODE           CONSTANT VARCHAR2(8)   := 'ER_05';
    C_ERR_05_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: номер сделки=''%s'' не найден';
    C_ERR_06_CODE           CONSTANT VARCHAR2(8)   := 'ER_06';
    C_ERR_06_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: тикер бумаги=''%s'' не найден';
    C_ERR_99_CODE           CONSTANT VARCHAR2(8)   := 'ER_99';
    C_ERR_99_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: другая ошибка';

    -- Параметры входного запроса
    v_rd                    DATE;                 -- Дата отчёта
    v_client_code           VARCHAR2(64);         -- ЕКК клиента
    v_client_name           VARCHAR2(120);        -- ФИО или часть ФИО клиента
    v_deal_num              VARCHAR2(30);         -- № сделки
    v_deal_type_list        SYS.ODCIVARCHAR2LIST; -- Направление сделки
    v_ticker                VARCHAR2(35);         -- Тикер бумаги
    v_market_files_obj      JSON_OBJECT_T;        -- Объект Биржевых файлов

    -- Переменные
    v_json_obj              JSON_OBJECT_T;
    v_has_args              BOOLEAN := FALSE;
    v_exMeta_arr            JSON_ARRAY_T := JSON_ARRAY_T();
    v_json_output           CLOB;
    v_inserted_rows         INTEGER;
    v_is_clear              INTEGER;
    v_sql                   VARCHAR2(2048);
    v_tmp_clob              CLOB;

    -- Валидация
    v_is_ekk_exists         CHAR(1)      := '0'; -- 1 - если ЕКК найден в СОФР или QUIK, иначе - 0
    v_is_fio_exists         CHAR(1)      := '0'; -- 1 - если ФИО найден в СОФР, иначе - 0
    v_is_deal_num_exists    CHAR(1)      := '0'; -- 1 - если сделка с указанным номером найдена в СОФР или Биржевом файле, иначе - 0
    v_is_ticker_exists      CHAR(1)      := '0'; -- 1 - если сделка с указанным тикером найдена в СОФР или Биржевом файле, иначе - 0
    v_market_files_has_err  BOOLEAN      := FALSE;
    v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
  BEGIN
    it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Сверка СОФР-Биржа, Фондовый рынок', it_log.C_MSG_TYPE__DEBUG);

    -- Парсим входной JSON, предварительно исключив массив с содержимым биржевых файлов
    v_sql := '
        SELECT JSON_TRANSFORM(:j, REMOVE ''' || C_MARKET_FILE_JPATH__STOCKS || ''')
        FROM dual';
    EXECUTE IMMEDIATE v_sql INTO v_tmp_clob USING p_json_input;
    v_json_obj := JSON_OBJECT_T.PARSE(v_tmp_clob);

    v_rd := TO_DATE(v_json_obj.get_string(C_IN_REPORT_DATE_TAG), C_IN_DATE_FORMAT);
    v_client_code := UPPER(v_json_obj.get_string(C_IN_CLIENT_CODE_TAG));
    v_client_name := UPPER(v_json_obj.get_string(C_IN_CLIENT_NAME_TAG));
    v_ticker := UPPER(v_json_obj.get_string(C_IN_TICKER_TAG));
    v_deal_num := UPPER(v_json_obj.get_string(C_IN_DEAL_NUM_TAG));
    v_deal_type_list := GetArrayFromJsonField(p_json_input, C_IN_DEAL_TYPE_TAG);
    v_market_files_obj := v_json_obj.get_object(C_MARKET_FILE_TAG__STOCKS);

    -- Если нет даты, отдаем мета-данные формы
    v_has_args := v_rd IS NOT NULL;
    IF NOT v_has_args THEN
      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Дата отчёта не указана, возвращаем Meta UI формы: Сверка СОФР-Биржа, Фондовый рынок', it_log.C_MSG_TYPE__DEBUG);
      RETURN BuildJsonOutput(p_exmeta_array => AddCamelToExMetaArr(v_exMeta_arr, C_STOCKS_M_CAMEL_ROUTEID, C_STOCKS_M_CAMEL_SCRIPT),
                             p_body => StockMarketReportMetaUI());
    END IF;

    -- Проверяем наличие биржевых файлов
    v_market_files_has_err := AppendIfNotNull(v_errors_array,
                                              GetMarketFileErrObj(p_trace_id_input, v_rd, 'DDMMYYYY',  v_market_files_obj));

    IF (p_is_production = 0) THEN
      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Парсинг входных параметров завершен: Сверка СОФР-Биржа, Фондовый рынок', it_log.C_MSG_TYPE__DEBUG,
                 'Параметры отчёта: ' ||
                 'report_date=' || TO_CHAR(v_rd, 'YYYY-MM-DD') || ', ' ||
                 'client_code=' || COALESCE(v_client_code, 'NULL') || ', ' ||
                 'client_name=' || COALESCE(v_client_name, 'NULL') || ', ' ||
                 'ticker=' || COALESCE(v_ticker, 'NULL') || ', ' ||
                 'deal_num=' || COALESCE(v_deal_num, 'NULL') || ', ' ||
                 'deal_type_list_count=' || CASE
                                                  WHEN v_deal_type_list IS NULL THEN '0'
                                                  ELSE TO_CHAR(v_deal_type_list.COUNT)
                                              END || ', ' ||
                 'market_files_has_error=' || CASE
                                                WHEN v_market_files_has_err THEN 'TRUE'
                                                ELSE 'FALSE'
                                              END);
    END IF;

    -- Валидация входных параметров
    -- В СОФР или Биржевом файле найдены сделки с указанными ЕКК
    SELECT
      CASE
        WHEN v_client_code IS NULL OR v_client_code = '' THEN 1
        WHEN EXISTS (SELECT 1 FROM ddlobjcode_dbt sofr WHERE UPPER(sofr.t_code) = v_client_code) THEN 1
        WHEN EXISTS (SELECT 1 FROM dbdui_sem03_file_dbt market_file WHERE market_file.t_client_code_m = v_client_code) THEN 1
        ELSE 0
      END
    INTO v_is_ekk_exists
    FROM dual;

    -- В СОФР существует клиент с введенным ФИО
    SELECT
      CASE
        WHEN v_client_name IS NULL OR v_client_name = '' THEN 1
        WHEN EXISTS (SELECT 1 FROM dparty_dbt cl WHERE UPPER(cl.t_name) LIKE '%' || v_client_name || '%') THEN 1
        ELSE 0
      END
    INTO v_is_fio_exists
    FROM dual;

    -- В СОФР или биржевом файле существует сделка с указанным номером
    SELECT
      CASE
        WHEN v_deal_num IS NULL OR v_deal_num = '' THEN 1
        WHEN EXISTS (SELECT 1 FROM dbdui_sem03_file_dbt mf WHERE mf.t_code_m = v_deal_num) THEN 1
        WHEN EXISTS (SELECT 1 FROM ddl_tick_dbt sofr WHERE sofr.t_dealcodets = v_deal_num) THEN 1
        ELSE 0
      END
    INTO v_is_deal_num_exists
    FROM dual;

    -- В СОФР или биржевом файле существует сделка с указанным тикером
    SELECT
      CASE
        WHEN v_ticker IS NULL OR v_ticker = '' THEN 1
        WHEN EXISTS (SELECT 1 FROM dbdui_sem03_file_dbt mf WHERE mf.t_isin_m = v_ticker) THEN 1
        WHEN EXISTS (SELECT 1 FROM dobjcode_dbt sofr WHERE sofr.t_codekind = 11 AND sofr.t_code = v_ticker) THEN 1
        ELSE 0
      END
    INTO v_is_ticker_exists
    FROM dual;

    IF (v_is_ekk_exists = '0') THEN
      v_errors_array.append(GetErrorObjAndLog(p_trace_id_input,C_ERR_03_CODE,
                                              UTL_LMS.FORMAT_MESSAGE(C_ERR_03_MSG, v_client_code)));
    END IF;
    IF (v_is_fio_exists = '0') THEN
      v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_04_CODE,
                                              UTL_LMS.FORMAT_MESSAGE(C_ERR_04_MSG, v_client_name)));
    END IF;
    IF (v_is_deal_num_exists = '0') THEN
      v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_05_CODE,
                                              UTL_LMS.FORMAT_MESSAGE(C_ERR_05_MSG, v_deal_num)));
    END IF;
    IF (v_is_ticker_exists = '0') THEN
      v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_06_CODE,
                                              UTL_LMS.FORMAT_MESSAGE(C_ERR_06_MSG, v_ticker)));
    END IF;

    IF v_errors_array.get_size() > 0 THEN
      RAISE NO_DATA_FOUND;
    END IF;

    -- Парсим биржевой файл
    SELECT ClearTmpSem03 INTO v_is_clear FROM dual; -- Очистим временную таблицу, на случай, если там что-то есть
    v_inserted_rows := ParseMarketFiles(p_trace_id_input, p_json_input, C_MARKET_FILE_TAG__STOCKS, C_MARKET_FILE_JPATH__STOCKS);

    -- Генерация JSON отчёта
    WITH
      leg_deal_ref AS (
        SELECT leg.t_maturity, leg.t_dealid
        FROM dbdui_sem03_file_dbt market_file
        LEFT JOIN ddl_tick_dbt sofr
          ON market_file.t_sofr_dealcode = sofr.t_dealcode AND sofr.t_clientid <> -1
        LEFT JOIN ddl_leg_dbt leg
          ON leg.t_dealid = sofr.t_dealid
      ),
      leg AS ( -- Детализация по сделке
        SELECT /*+ MATERIALIZE */ leg2.t_maturity real_mat, leg1.*
        FROM ddl_leg_dbt leg1
               JOIN (SELECT t.t_dealid, MAX(t.t_maturity) t_maturity, COUNT(t.t_maturity) cnt
                     FROM leg_deal_ref t
                     GROUP BY t_dealid) leg2
                 ON leg1.t_dealid = leg2.t_dealid
                   AND ((leg1.t_maturity <> leg2.t_maturity AND leg2.cnt = 2) OR (leg1.t_maturity = leg2.t_maturity AND leg2.cnt = 1))
      ),
      client_m AS (
        SELECT /*+ MATERIALIZE */ DISTINCT cl.t_partyid, ekk.t_mpcode, cl.t_name, client_doc.t_paperseries, client_doc.t_papernumber
        FROM ddl_clientinfo_dbt ekk
               LEFT JOIN dparty_dbt cl
                         ON ekk.t_partyid = cl.t_partyid
               LEFT JOIN dpersnidc_dbt client_doc -- Паспортные данные клиента
                         ON ekk.t_partyid = client_doc.t_personid
                              AND client_doc.t_ismain = 'X'
      ),
      ekk AS (SELECT c.t_code AS t_ekk, m.t_sfcontrid
              FROM ddlcontrmp_dbt m
                JOIN ddlobjcode_dbt c
                  ON c.t_objectid = m.t_dlcontrid
                  AND c.t_objecttype = 207
                  AND c.t_codekind = 1
      ),
      tic AS (SELECT t.t_code, t.t_objectid, t.t_bankdate -- Тикер может меняться со временем, поэтому необходимо выбрать тот, который был актуален на дату построения отчёта
              FROM dobjcode_dbt t
              WHERE t.t_codekind = 11
                AND t.t_bankdate <= v_rd + 1 -- IMPROVE: вероятно, лютый костыль: почему-то дата начала тикера t_bankdate может оказаться на 1 день позже самой даты сделки
                AND (t.t_bankclosedate > v_rd + 1 -- IMPROVE: вероятно, лютый костыль: почему-то дата начала тикера t_bankdate может оказаться на 1 день позже самой даты сделки
                OR t.t_bankclosedate = DATE '0001-01-01') -- Спец дата, если тикер действующий в настоящее время
      ),
      result AS (
        SELECT
          market_file.t_code_m                                                         AS t_code_m,        -- Внешний номер сделки из биржевого файла
          sofr.t_dealcodets                                                            AS t_code_s,        -- Внешний номер сделки из БД СОФР
          market_file.t_date_m                                                         AS t_date_m,        -- Дата сделки биржа
          sofr.t_dealdate                                                              AS t_date_s,        -- Дата сделки СОФР
          market_file.t_time_m                                                         AS t_time_m,        -- Время сделки биржа
          sofr.t_dealdate + (sofr.t_dealtime - TRUNC(sofr.t_dealtime))                 AS t_time_s,        -- Время сделки СОФР
          market_file.t_date_clr_m                                                     AS t_date_clr_m,    -- Дата клиринга биржа
          leg.real_mat                                                                 AS t_date_clr_s,    -- Дата клиринга СОФР
          market_file.t_client_code_m                                                  AS t_client_code_m, -- ЕКК клиента биржа
          ekk.t_ekk                                                                    AS t_client_code_s, -- ЕКК клиента СОФР
          client_m.t_name                                                              AS t_client_name_m, -- Клиент биржа
          client_s.t_name                                                              AS t_client_name_s, -- Клиент СОФР
          market_file.t_details_m                                                      AS t_details_m,     -- Информация по клиенту биржа
          REPLACE(client_m.t_paperseries || client_m.t_papernumber, ' ', '')           AS t_details_s,     -- Информация по клиенту СОФР
          market_file.t_oper_m                                                         AS t_oper_m,        -- Вид сделки биржа
          CASE
            WHEN UPPER(deal.t_name) LIKE '%ПОКУПКА%' THEN 'B'
            WHEN UPPER(deal.t_name) LIKE '%ПРОДАЖА%' THEN 'S'
            ELSE deal.t_name
          END                                                                          AS t_oper_s,        -- Вид сделки СОФР
          market_file.t_quantity_m                                                     AS t_quantity_m,    -- Кол-во биржа
          leg.t_principal                                                              AS t_quantity_s,    -- Кол-во СОФР
          market_file.t_amount_m                                                       AS t_amount_m,      -- Объём биржа
          leg.t_totalcost                                                              AS t_amount_s,      -- Объём СОФР
          market_file.t_isin_m                                                         AS t_isin_m,        -- Уникальный тикер бумаги биржа
          tic.t_code                                                                   AS t_isin_s,        -- Уникальный тикер бумаги СОФР
          market_file.t_secname_m                                                      AS t_secname_m,     -- Название бумаги биржа
          tagfi.t_name                                                                 AS t_secname_s,     -- Название бумаги СОФР
          COALESCE(dog.t_number, rsb_secur.getdealsfcontrnumber(sofr.t_clientcontrid)) AS t_dog            -- Номер договора СОФР
        FROM dbdui_sem03_file_dbt market_file
          LEFT JOIN ddl_tick_dbt sofr -- Таблица со сделками
                    ON market_file.t_sofr_dealcode = sofr.t_dealcode
          LEFT JOIN dparty_dbt client_s -- Субъекты экономики (СОФР)
                    ON client_s.t_partyid = sofr.t_clientid
          LEFT JOIN client_m -- Субъекты экономики (Биржа)
                    ON client_m.t_mpcode = market_file.t_client_code_m
                      AND (p_is_production = 0 OR market_file.t_details_m = REPLACE(client_m.t_paperseries || client_m.t_papernumber, ' ', ''))
          LEFT JOIN leg -- Детализация по сделке
                    ON leg.t_dealid = sofr.t_dealid
          LEFT JOIN doprkoper_dbt deal -- Расшифровка направления сделки
                    ON deal.t_kind_operation = sofr.t_dealtype
          LEFT JOIN dfininstr_dbt tagfi -- Название ценной бумаги
                    ON tagfi.t_fiid = leg.t_pfi
          LEFT JOIN dsfcontr_dbt dog -- Номер договора
                    ON dog.t_id = sofr.t_clientcontrid
          LEFT JOIN davrkinds_dbt kind -- Вид ценной бумаги
                    ON tagfi.t_fi_kind = kind.t_fi_kind
                      AND tagfi.t_avoirkind = kind.t_avoirkind
          LEFT JOIN ekk -- ЕКК клиента
                    ON ekk.t_sfcontrid = sofr.t_clientcontrid
          LEFT JOIN tic -- наименование уникального тикета сделки
                    ON tic.t_objectid = tagfi.t_fiid
        WHERE 1=1
          AND market_file.t_date_m = v_rd
          AND (v_client_code IS NULL OR v_client_code = '' OR market_file.t_client_code_m = v_client_code)
          AND (v_client_name IS NULL OR v_client_name = '' OR UPPER(client_m.t_name) LIKE '%'|| v_client_name || '%')
          AND (v_deal_num IS NULL OR v_deal_num = '' OR UPPER(market_file.t_code_m) = v_deal_num)
          AND (v_ticker IS NULL OR v_ticker = '' OR UPPER(market_file.t_isin_m) = v_ticker)
          AND (NOT EXISTS (SELECT 1 FROM TABLE(v_deal_type_list))
               OR market_file.t_oper_m IN (SELECT COLUMN_VALUE FROM TABLE(v_deal_type_list)))
      )
    -- Строим напрямую через SQL JSON, а не PL/SQL JSON Object Types для экономии ресурсов
    SELECT (
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'code_m'        VALUE t_code_m,
                'code_s'        VALUE t_code_s,
                'date_m'        VALUE t_date_m,
                'date_s'        VALUE t_date_s,
                'time_m'        VALUE t_time_m,
                'time_s'        VALUE t_time_s,
                'date_clr_m'    VALUE t_date_clr_m,
                'date_clr_s'    VALUE t_date_clr_s,
                'client_code_m' VALUE t_client_code_m,
                'client_code_s' VALUE t_client_code_s,
                'client_name_m' VALUE t_client_name_m,
                'client_name_s' VALUE t_client_name_s,
                'deal_type_m'   VALUE t_oper_m,
                'deal_type_s'   VALUE t_oper_s,
                'quantity_m'    VALUE t_quantity_m,
                'quantity_s'    VALUE t_quantity_s,
                'amount_m'      VALUE t_amount_m,
                'amount_s'      VALUE t_amount_s,
                'isin_m'        VALUE t_isin_m,
                'isin_s'        VALUE t_isin_s,
                'secname_m'     VALUE t_secname_m,
                'secname_s'     VALUE t_secname_s,
                'no_dog_s'      VALUE t_dog
            ) RETURNING CLOB
        )
    )
    INTO v_json_output
    FROM (
        SELECT r.*
        FROM result r
        UNION ALL
        -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
        SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
        FROM dual
        WHERE NOT EXISTS (SELECT 1 FROM result)
    );

    v_json_output := BuildSplitJsonOutput(p_trace_id_input => p_trace_id_input,
                                          p_json_input => v_json_output,
                                          p_report_date_input => v_rd,
                                          p_report_tag => C_REPORT_NAME_TAG,
                                          p_items_arr_tag => C_ITEMS_ARR_TAG,
                                          p_template_name => C_TEMPLATE_NAME,
                                          p_output_file_name => C_OUTPUT_FILE_NAME,
                                          p_s3_file_name => C_S3_FILE_NAME);

    it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Построение отчёта успешно завершено: Сверка СОФР-Биржа, Фондовый рынок', it_log.C_MSG_TYPE__DEBUG);
    RETURN v_json_output;

    EXCEPTION
      WHEN OTHERS THEN
        -- Если массив ошибок пустой, но мы всё равно сюда попали, значит произошло что-то непредвиденное
        it_error.put_error_in_stack;
        IF (v_errors_array.get_size() = 0) THEN
          v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                  C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
        END IF;

        RETURN BuildJsonOutput(p_errors_array => v_errors_array);
  END StockMarket_RC_ReportRun;


  -------------------------------------------------------------------------------------------------------------
  ----- Парсинг биржевого файла CUX23 (для сделок на валютном рынке) во временную таблицу DBDUI_CUX23_FILE_DBT -----
  -------------------------------------------------------------------------------------------------------------
  FUNCTION ParseCUX23(p_trace_id_input VARCHAR2, p_xml CLOB)
    RETURN INTEGER
  IS
  BEGIN
    -- Сообщение стоит включать исключительно для отладки, дабы не грузить базу сохранением лишних CLOB'ов
    --     it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Получен биржевой файл валютного рынка, парсинг запущен', it_log.C_MSG_TYPE__DEBUG, p_xml);
    it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Получен биржевой файл валютного рынка, парсинг запущен', it_log.C_MSG_TYPE__DEBUG);

    INSERT INTO dbdui_cux23_file_dbt (
      T_CODE_M,
      T_DATE_M,
      T_TIME_M,
      T_DATE_CLR_M,
      T_CLIENT_CODE_M,
      T_DETAILS_M,
      T_OPER_M,
      T_QUANTITY_M,
      T_PRICE_M,
      T_CUR_PAIR_M
    )
    WITH
      parsed_xml AS (
        SELECT
          UPPER(T_CODE)                                    AS T_CODE_M,
          TO_DATE(T_DATE, 'YYYY-MM-DD')                    AS T_DATE_M,
          TO_TIMESTAMP(T_DATE || ' ' || T_TIME,
                       'YYYY-MM-DD HH24:MI:SS')            AS T_TIME_M,
          TO_DATE(T_DATE_CLR, 'YYYY-MM-DD')                AS T_DATE_CLR_M,
          UPPER(T_CLIENT_CODE)                             AS T_CLIENT_CODE_M,
          T_DETAILS                                        AS T_DETAILS_M,
          rec.T_OPER                                       AS T_OPER_M,
          ToLocalNumber(T_QUANTITY)                        AS T_QUANTITY_M,
          ToLocalNumber(T_PRICE)                           AS T_PRICE_M,
          UPPER(T_CURRENCY) || '/' || UPPER(T_CO_CURRENCY) AS T_CUR_PAIR_M
        FROM
          XMLTABLE(
                  '/MICEX_DOC/CUX23'
                  PASSING XMLTYPE(p_xml)
                  COLUMNS
                      T_DATE  VARCHAR2(20) PATH '@ReportDate',
                      cux_xml XMLTYPE PATH '.'
          ) AS cux23,
          XMLTABLE(
                  '//CLEARPART/SETTLE/TRADEACC/SESSION/CURRPAIR'
                  PASSING cux23.cux_xml
                  COLUMNS
                      T_CURRENCY    VARCHAR2(40) PATH '@CurrencyId',
                      T_CO_CURRENCY VARCHAR2(40) PATH '@CoCurrencyId',
                      currpair_xml XMLTYPE PATH '.'
          ) AS currpair,
          XMLTABLE(
                  '//SECURITY/SETTLEDATE'
                  PASSING currpair.currpair_xml
                  COLUMNS
                      T_DATE_CLR VARCHAR2(35) PATH '@SettleDate',
                      settle_xml XMLTYPE PATH '.'
          ) AS settle,
          XMLTABLE(
                  '//GROUP/MAINSEC/RECORDS'
                  PASSING settle.settle_xml
                  COLUMNS
                      T_CODE VARCHAR2(30) PATH '@TradeNo',
                      T_TIME VARCHAR2(20) PATH '@TradeTime',
                      T_CLIENT_CODE VARCHAR2(64) PATH '@ClientCode',
                      T_DETAILS VARCHAR2(64) PATH 'translate(@Details, " ", "")',
                      T_OPER VARCHAR2(79) PATH '@BuySell',
                      T_QUANTITY VARCHAR2(64) PATH '@Quantity' DEFAULT 0,
                      T_PRICE VARCHAR2(64) PATH '@Price' DEFAULT 0
          ) rec
        WHERE T_CLIENT_CODE IS NOT NULL
      )
    SELECT *
    FROM parsed_xml;
    it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Парсинг биржевого файла валютного рынка завершен, получено строк: ' || SQL%ROWCOUNT, it_log.C_MSG_TYPE__DEBUG);
    RETURN SQL%ROWCOUNT;
  EXCEPTION
    WHEN OTHERS THEN
      it_error.put_error_in_stack;
      RAISE_APPLICATION_ERROR(-20001, 'Ошибка парсинга XML: ' || SQLERRM);
  END ParseCUX23;


  -------------------------------------------------------------------------------------
  ----- Формирование UI Form для Отчёта Сверка сделок: СОФР-Биржа, Валютный рынок -----
  -------------------------------------------------------------------------------------
  FUNCTION CurrencyMarketReportMetaUI
      RETURN CLOB
  IS
      C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
      C_REPORT_LOCALIZED_NAME VARCHAR2(128) := 'Сверка сделок: СОФР-Биржа, Валютный рынок';
      C_SYS_TAGS              VARCHAR2(256) := '["ORACLE","Exchange"]';
      v_meta_ui               CLOB;
  BEGIN
      WITH
          deal_types(name, value) AS (
              SELECT 'Покупка', 'B' FROM dual
              UNION ALL
              SELECT 'Продажа', 'S' FROM dual
          ),
          cur_pairs(curPair) AS (
              SELECT DISTINCT fin1.t_ccy || '/' || fin2.t_ccy curpair
              FROM ddvndeal_dbt t -- Таблица со сделками
                       LEFT JOIN ddvnfi_dbt nfi -- Детали по сделке
                                 ON nfi.t_dealid = t.t_id
                       LEFT JOIN dfininstr_dbt fin1
                                 ON fin1.t_fiid = nfi.t_fiid
                       LEFT JOIN dfininstr_dbt fin2
                                 ON fin2.t_fiid = nfi.t_stdfiid
                       LEFT JOIN dnamealg_dbt namealg
                            ON namealg.t_inumberalg = t.t_marketkind
              WHERE 1=1
                AND namealg.t_sznamealg = 'Валютный'
                AND namealg.t_itypealg = 7039
                AND nfi.t_fiid != -1
                AND nfi.t_stdfiid != -1
              ORDER BY curpair)
      SELECT
          JSON_OBJECT(
              C_META_UI_TAG__ROLES   VALUE C_ROLES FORMAT JSON,
              C_META_UI_TAG__LABEL   VALUE C_REPORT_LOCALIZED_NAME,
              C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
              C_META_UI_TAG__FORM    VALUE JSON_ARRAY(
                  -- Первая строка
                  JSON_ARRAY(
                      JSON_OBJECT(
                          'label'    VALUE 'Дата сделки',
                          'name'     VALUE 'reportDate',
                          'type'     VALUE 'date',
                          'required' VALUE 'true' FORMAT JSON,
                          'column'   VALUE 0,
                          'default'  VALUE TO_CHAR(sysdate, 'YYYY-MM-DD')
                          RETURNING CLOB
                      ),
                      JSON_OBJECT(
                          'label'    VALUE 'ЕКК клиента',
                          'name'     VALUE 'clientCode',
                          'type'     VALUE 'text',
                          'required' VALUE 'false' FORMAT JSON,
                          'column'   VALUE 1,
                          'default'  VALUE ''
                          RETURNING CLOB
                      ),
                      JSON_OBJECT(
                          'label'    VALUE 'Направление сделки',
                          'name'     VALUE 'dealType',
                          'type'     VALUE 'select',
                          'required' VALUE 'true' FORMAT JSON,
                          'column'   VALUE 2,
                          'default'  VALUE (
                              SELECT JSON_ARRAYAGG(value RETURNING CLOB)
                              FROM deal_types
                          ),
                          'multiselect' VALUE 'true' FORMAT JSON,
                          'items'       VALUE (
                              SELECT JSON_ARRAYAGG(
                                  JSON_OBJECT(
                                          'name'  VALUE name,
                                          'value' VALUE value
                                  ) RETURNING CLOB
                              )
                              FROM deal_types
                          )
                          RETURNING CLOB
                      )
                  ),
                  -- Вторая строка
                  JSON_ARRAY(
                      JSON_OBJECT(
                          'label'    VALUE 'Номер сделки',
                          'name'     VALUE 'dealNum',
                          'type'     VALUE 'text',
                          'required' VALUE 'false' FORMAT JSON,
                          'column'   VALUE 0,
                          'default'  VALUE ''
                          RETURNING CLOB
                      ),
                      JSON_OBJECT(
                          'label'    VALUE 'ФИО клиента',
                          'name'     VALUE 'clientName',
                          'type'     VALUE 'text',
                          'required' VALUE 'false' FORMAT JSON,
                          'column'   VALUE 1,
                          'default'  VALUE ''
                          RETURNING CLOB
                      ),
                      JSON_OBJECT(
                          'label'    VALUE 'Валютная пара',
                          'name'     VALUE 'curPair',
                          'type'     VALUE 'select',
                          'required' VALUE 'true' FORMAT JSON,
                          'column'   VALUE 2,
                          'default'  VALUE (
                              SELECT JSON_ARRAYAGG(curpair RETURNING CLOB)
                              FROM cur_pairs
                          ),
                          'multiselect' VALUE 'true' FORMAT JSON,
                          'items'       VALUE (
                              SELECT JSON_ARRAYAGG(
                                             JSON_OBJECT(
                                                     'name'  VALUE curpair,
                                                     'value' VALUE curpair
                                             ) RETURNING CLOB
                                     )
                              FROM cur_pairs
                          )
                          RETURNING CLOB
                      )
                  )
              ) RETURNING CLOB
          )
      INTO v_meta_ui
      FROM dual;

      RETURN v_meta_ui;
  END CurrencyMarketReportMetaUI;

  FUNCTION ClearTmpCux23
    RETURN INTEGER
  IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    DELETE FROM dbdui_cux23_file_dbt;
    COMMIT;
    RETURN 1;
  END;

  ------------------------------------------------------------------------------------------
  ----- Формирование Отчёта сравнения данных СОФР-Биржа, Валютный рынок -----
  ------------------------------------------------------------------------------------------
  FUNCTION CurrencyMarket_RC_ReportRun(p_trace_id_input VARCHAR2,
                                       p_json_input CLOB,
                                       p_is_production CHAR DEFAULT '1' -- Флаг для режима прода:
                                       -- Включает режим продакшн
                                       --  1 - выборка клиента будет происходить в соответствии с паспортными данными клиента
                                       --  0 - паспортные данные игнорируются при выборке клиента (т.к. данные обезличены, а в паспорте рандомные цифры)
  )
      RETURN CLOB
  IS
      -- Константы
      C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := 'sofr_market_cux23';
      C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Сверка_СОФР-биржа_валютный_рынок';
      C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := 'currencymarket_report';
      C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'GetCurrencyMarket';
      C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'deals';

      -- Входной JSON
      C_IN_REPORT_DATE_TAG    CONSTANT VARCHAR2(32)  := 'reportDate';
      C_IN_CLIENT_CODE_TAG    CONSTANT VARCHAR2(32)  := 'clientCode';
      C_IN_CLIENT_NAME_TAG    CONSTANT VARCHAR2(32)  := 'clientName';
      C_IN_DEAL_TYPE_TAG      CONSTANT VARCHAR2(32)  := 'dealType';
      C_IN_DEAL_NUM_TAG       CONSTANT VARCHAR2(32)  := 'dealNum';
      C_IN_CURPAIR_TAG        CONSTANT VARCHAR2(32)  := 'curPair';
      C_IN_DATE_FORMAT        CONSTANT VARCHAR2(32)  := 'YYYY-MM-DD';

      -- Константы - Ошибки
      C_ERR_03_CODE           CONSTANT VARCHAR2(8)   := 'ER_03';
      C_ERR_03_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: клиент по ЕКК=''%s'' не найден';
      C_ERR_04_CODE           CONSTANT VARCHAR2(8)   := 'ER_04';
      C_ERR_04_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: клиент по ФИО=''%s'' не найден';
      C_ERR_05_CODE           CONSTANT VARCHAR2(8)   := 'ER_05';
      C_ERR_05_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: номер сделки=''%s'' не найден';
      C_ERR_99_CODE           CONSTANT VARCHAR2(8)   := 'ER_99';
      C_ERR_99_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: другая ошибка';

      -- Параметры входного запроса
      v_rd                    DATE;                 -- Дата отчёта
      v_client_code           VARCHAR2(64);         -- ЕКК клиента
      v_client_name           VARCHAR2(120);        -- ФИО или часть ФИО клиента
      v_deal_num              VARCHAR2(30);         -- № сделки
      v_deal_type_list        SYS.ODCIVARCHAR2LIST; -- Направление сделки
      v_cur_pair_list              SYS.ODCIVARCHAR2LIST; -- Валютные пары
      v_market_files_obj      JSON_OBJECT_T;        -- Объект Биржевых файлов

      -- Переменные
      v_json_obj              JSON_OBJECT_T;
      v_has_args              BOOLEAN := FALSE;
      v_json_output           CLOB;
      v_inserted_rows         INTEGER;
      v_exMeta_arr            JSON_ARRAY_T := JSON_ARRAY_T();
      v_is_clear              INTEGER;
      v_sql                   VARCHAR2(2048);
      v_tmp_clob              CLOB;

      -- Валидация
      v_is_ekk_exists         CHAR(1)      := '0'; -- 1 - если ЕКК найден в СОФР или QUIK, иначе - 0
      v_is_fio_exists         CHAR(1)      := '0'; -- 1 - если ФИО найден в СОФР, иначе - 0
      v_is_deal_num_exists    CHAR(1)      := '0'; -- 1 - если сделка с указанным номером найдена в СОФР или Биржевом файле, иначе - 0
      v_market_files_has_err  BOOLEAN      := FALSE;
      v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
  BEGIN
      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Сверка сделок: СОФР-Биржа, Валютный рынок', it_log.C_MSG_TYPE__DEBUG);

      -- Парсим входной JSON, предварительно исключив массив с содержимым биржевых файлов
      v_sql := '
        SELECT JSON_TRANSFORM(:j, REMOVE ''' || C_MARKET_FILE_JPATH__FOREX || ''')
        FROM dual';
      EXECUTE IMMEDIATE v_sql INTO v_tmp_clob USING p_json_input;
      v_json_obj := JSON_OBJECT_T.PARSE(v_tmp_clob);

      v_rd := TO_DATE(v_json_obj.get_string(C_IN_REPORT_DATE_TAG), C_IN_DATE_FORMAT);
      v_client_code := UPPER(v_json_obj.get_string(C_IN_CLIENT_CODE_TAG));
      v_client_name := UPPER(v_json_obj.get_string(C_IN_CLIENT_NAME_TAG));
      v_cur_pair_list := GetArrayFromJsonField(p_json_input, C_IN_CURPAIR_TAG);
      v_deal_num := UPPER(v_json_obj.get_string(C_IN_DEAL_NUM_TAG));
      v_deal_type_list := GetArrayFromJsonField(p_json_input, C_IN_DEAL_TYPE_TAG);
      v_market_files_obj := v_json_obj.get_object(C_MARKET_FILE_TAG__FOREX);

      -- Если нет даты, отдаем мета-данные формы
      v_has_args := v_rd IS NOT NULL;
      IF NOT v_has_args THEN
        it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Дата отчёта не указана, возвращаем Meta UI формы: Сверка СОФР-Биржа, Валютный рынок', it_log.C_MSG_TYPE__DEBUG);
        RETURN BuildJsonOutput(p_exmeta_array => AddCamelToExMetaArr(v_exMeta_arr, C_FOREX_M_CAMEL_ROUTEID, C_FOREX_M_CAMEL_SCRIPT),
                               p_body => CurrencyMarketReportMetaUI());
      END IF;

      -- Проверяем наличие биржевых файлов
      v_market_files_has_err := AppendIfNotNull(v_errors_array,
                                                GetMarketFileErrObj(p_trace_id_input, v_rd, 'DDMMYYYY', v_market_files_obj));

      IF (p_is_production = 0) THEN
        it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Парсинг входных параметров завершен: Сверка СОФР-Биржа, Валютный рынок', it_log.C_MSG_TYPE__DEBUG,
                   'Параметры отчёта: ' ||
                   'report_date=' || TO_CHAR(v_rd, 'YYYY-MM-DD')     || ', ' ||
                   'client_code=' || COALESCE(v_client_code, 'NULL') || ', ' ||
                   'client_name=' || COALESCE(v_client_name, 'NULL') || ', ' ||
                   'cur_pair='    || CASE
                                          WHEN v_cur_pair_list IS NULL THEN '0'
                                          ELSE TO_CHAR(v_cur_pair_list.COUNT)
                                     END || ', ' ||
                   'deal_num='    || COALESCE(v_deal_num, 'NULL')    || ', ' ||
                   'deal_type_list_count=' || CASE
                                                WHEN v_deal_type_list IS NULL THEN '0'
                                                ELSE TO_CHAR(v_deal_type_list.COUNT)
                                              END || ', ' ||
                   'market_files_has_error=' || CASE
                                                  WHEN v_market_files_has_err THEN 'TRUE'
                                                  ELSE 'FALSE'
                                                END);
      END IF;

      -- Валидация входных параметров
      -- В СОФР или Биржевом файле найдены сделки с указанными ЕКК
      SELECT
          CASE
              WHEN v_client_code IS NULL OR v_client_code = '' THEN 1
              WHEN EXISTS (SELECT 1 FROM ddlcontrmp_dbt sofr WHERE sofr.t_mpcode = v_client_code) THEN 1
              WHEN EXISTS (SELECT 1 FROM dbdui_cux23_file_dbt market_file WHERE market_file.t_client_code_m = v_client_code) THEN 1
              ELSE 0
              END
      INTO v_is_ekk_exists
      FROM dual;

      -- В СОФР существует клиент с введенным ФИО
      SELECT
          CASE
              WHEN v_client_name IS NULL OR v_client_name = '' THEN 1
              WHEN EXISTS (SELECT 1 FROM dparty_dbt cl WHERE UPPER(cl.t_name) LIKE '%' || v_client_name || '%') THEN 1
              ELSE 0
              END
      INTO v_is_fio_exists
      FROM dual;

      -- В СОФР или биржевом файле существует сделка с указанным номером
      SELECT
          CASE
              WHEN v_deal_num IS NULL OR v_deal_num = '' THEN 1
              WHEN EXISTS (SELECT 1 FROM dbdui_cux23_file_dbt mf WHERE mf.t_code_m = v_deal_num) THEN 1
              WHEN EXISTS (SELECT 1 FROM ddvndeal_dbt sofr WHERE sofr.t_extcode = v_deal_num) THEN 1
              ELSE 0
              END
      INTO v_is_deal_num_exists
      FROM dual;

      IF (v_is_ekk_exists = '0') THEN
          v_errors_array.append(GetErrorObjAndLog(p_trace_id_input,C_ERR_03_CODE,
                                                  UTL_LMS.FORMAT_MESSAGE(C_ERR_03_MSG, v_client_code)));
      END IF;
      IF (v_is_fio_exists = '0') THEN
          v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_04_CODE,
                                                  UTL_LMS.FORMAT_MESSAGE(C_ERR_04_MSG, v_client_name)));
      END IF;
      IF (v_is_deal_num_exists = '0') THEN
          v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_05_CODE,
                                                  UTL_LMS.FORMAT_MESSAGE(C_ERR_05_MSG, v_deal_num)));
      END IF;

      IF v_errors_array.get_size() > 0 THEN
          RAISE NO_DATA_FOUND;
      END IF;

      -- Парсим биржевой файл
      SELECT ClearTmpCux23() INTO v_is_clear FROM dual; -- Очистим временную таблицу, на случай, если там что-то есть
      v_inserted_rows := ParseMarketFiles(p_trace_id_input, p_json_input, C_MARKET_FILE_TAG__FOREX, C_MARKET_FILE_JPATH__FOREX);

      -- Генерация JSON отчёта
      WITH
          client_m AS (
            SELECT /*+ MATERIALIZE */ DISTINCT cl.t_partyid, ekk.t_mpcode, cl.t_name, client_doc.t_paperseries, client_doc.t_papernumber
            FROM ddl_clientinfo_dbt ekk
                   LEFT JOIN dparty_dbt cl
                             ON ekk.t_partyid = cl.t_partyid
                   LEFT JOIN dpersnidc_dbt client_doc -- Паспортные данные клиента
                             ON ekk.t_partyid = client_doc.t_personid
                                  AND client_doc.t_ismain = 'X'
          ),
          result AS (
              SELECT
                  market_file.t_code_m                                                       AS t_code_m,        -- Внешний номер сделки из биржевого файла
                  sofr.t_extcode                                                             AS t_code_s,        -- Внешний номер сделки из БД СОФР
                  market_file.t_date_m                                                       AS t_date_m,        -- Дата сделки биржа
                  sofr.t_date                                                                AS t_date_s,        -- Дата сделки СОФР
                  market_file.t_time_m                                                       AS t_time_m,        -- Время сделки биржа
                  sofr.t_date + (sofr.t_time - TRUNC(sofr.t_time))                           AS t_time_s,        -- Время сделки СОФР
                  market_file.t_date_clr_m                                                   AS t_date_clr_m,    -- Дата клиринга биржа
                  nfi.t_paydate                                                              AS t_date_clr_s,    -- Дата клиринга СОФР
                  market_file.t_client_code_m                                                AS t_client_code_m, -- ЕКК клиента биржа
                  ekk_s.t_mpcode                                                             AS t_client_code_s, -- ЕКК клиента СОФР
                  client_m.t_name                                                            AS t_client_name_m, -- Клиент биржа
                  client_s.t_name                                                            AS t_client_name_s, -- Клиент СОФР
                  market_file.t_details_m                                                    AS t_details_m,     -- Информация по клиенту биржа
                  REPLACE(client_m.t_paperseries || client_m.t_papernumber, ' ', '')         AS t_details_s,     -- Информация по клиенту СОФР
                  market_file.t_oper_m                                                       AS t_oper_m,        -- Вид сделки биржа
                  CASE
                      WHEN UPPER(namealg.t_sznamealg) LIKE '%ПОКУПКА%' THEN 'B'
                      WHEN UPPER(namealg.t_sznamealg) LIKE '%ПРОДАЖА%' THEN 'S'
                      ELSE namealg.t_sznamealg
                  END                                                                    AS t_oper_s,        -- Вид сделки СОФР
                  market_file.t_quantity_m                                                   AS t_quantity_m,    -- Кол-во биржа
                  nfi.t_amount                                                               AS t_quantity_s,    -- Кол-во СОФР
                  market_file.t_cur_pair_m                                                   AS t_cur_pair_m,    -- Валютная пара биржа
                  fin1.t_ccy || '/' || fin2.t_ccy                                            AS t_cur_pair_s,    -- Валютная пара СОФР
                  ROUND(market_file.t_price_m, 4)                                            AS t_price_m,       -- Цена биржа
                  ROUND(nFI.t_price, 4)                                                      AS t_price_s,       -- Цена СОФР
                  COALESCE(dog.t_number, rsb_secur.getdealsfcontrnumber(sofr.t_clientcontr)) AS t_dog            -- Номер договора СОФР
              FROM dbdui_cux23_file_dbt market_file
                  LEFT JOIN ddvndeal_dbt sofr -- Таблица со сделками
                            ON market_file.t_code_m = sofr.t_extcode -- Номер сделки
                              AND sofr.t_code LIKE market_file.t_oper_m || '/%' -- Тип сделки (т.к. под одним номером, может быть тип как B, так и S)
                  LEFT JOIN dparty_dbt client_s -- Субъекты экономики (СОФР)
                            ON client_s.t_partyid = sofr.t_client
                  LEFT JOIN client_m -- Субъекты экономики (Биржа)
                            ON client_m.t_mpcode = market_file.t_client_code_m
                                AND (p_is_production = 0 OR market_file.t_details_m = REPLACE(client_m.t_paperseries || client_m.t_papernumber, ' ', ''))
                  LEFT JOIN ddvnfi_dbt nfi -- Детализация по сделке
                            ON nfi.t_dealid = sofr.t_id
                  LEFT JOIN dfininstr_dbt fin1 -- Валюта
                            ON fin1.t_fiid = nfi.t_fiid
                  LEFT JOIN dfininstr_dbt fin2 -- Контр-валюта
                            ON fin2.t_fiid = nfi.t_stdfiid
                  LEFT JOIN dnamealg_dbt namealg -- Расшифровка направления сделки
                       ON namealg.t_inumberalg = sofr.t_type
                           AND namealg.t_itypealg = 7004 -- ID с направлением сделки (волшебное число, полученное эмпирическим путём из толстого клиента СОФРа)
                  LEFT JOIN dsfcontr_dbt dog -- Номер договора
                            ON dog.t_id = sofr.t_clientcontr
                  LEFT JOIN ddlcontrmp_dbt ekk_s -- ЕКК клиента
                            ON ekk_s.t_sfcontrid = sofr.t_clientcontr
              WHERE 1=1
                  AND market_file.t_date_m = v_rd
                  AND (v_client_code IS NULL OR v_client_code = '' OR market_file.t_client_code_m = v_client_code)
                  AND (v_client_name IS NULL OR v_client_name = '' OR UPPER(client_m.t_name) LIKE '%'|| v_client_name || '%')
                  AND (v_deal_num IS NULL OR v_deal_num = '' OR UPPER(market_file.t_code_m) = v_deal_num)
                  AND (NOT EXISTS (SELECT 1 FROM TABLE(v_cur_pair_list))
                    OR UPPER(market_file.t_cur_pair_m) IN (SELECT COLUMN_VALUE FROM TABLE(v_cur_pair_list)))
                  AND (NOT EXISTS (SELECT 1 FROM TABLE(v_deal_type_list))
                    OR market_file.t_oper_m IN (SELECT COLUMN_VALUE FROM TABLE(v_deal_type_list)))
          )
      -- Строим напрямую через SQL JSON, а не PL/SQL JSON Object Types для экономии ресурсов
      SELECT (
          JSON_ARRAYAGG(
              JSON_OBJECT(
                  'code_m'        VALUE t_code_m,
                  'code_s'        VALUE t_code_s,
                  'date_m'        VALUE t_date_m,
                  'date_s'        VALUE t_date_s,
                  'time_m'        VALUE t_time_m,
                  'time_s'        VALUE t_time_s,
                  'date_clr_m'    VALUE t_date_clr_m,
                  'date_clr_s'    VALUE t_date_clr_s,
                  'client_code_m' VALUE t_client_code_m,
                  'client_code_s' VALUE t_client_code_s,
                  'client_name_m' VALUE t_client_name_m,
                  'client_name_s' VALUE t_client_name_s,
                  'deal_type_m'   VALUE t_oper_m,
                  'deal_type_s'   VALUE t_oper_s,
                  'cur_pair_m'    VALUE t_cur_pair_m,
                  'cur_pair_s'    VALUE t_cur_pair_s,
                  'quantity_m'    VALUE t_quantity_m,
                  'quantity_s'    VALUE t_quantity_s,
                  'price_m'       VALUE t_price_m,
                  'price_s'       VALUE t_price_s,
                  'no_dog_s'      VALUE t_dog
              ) RETURNING CLOB
          )
      )
      INTO v_json_output
      FROM (
          SELECT r.*
          FROM result r
          UNION ALL
          -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
          SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                 NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                 NULL, NULL, NULL, NULL, NULL, NULL
          FROM dual
          WHERE NOT EXISTS (SELECT 1 FROM result)
      );

      v_json_output := BuildSplitJsonOutput(p_trace_id_input => p_trace_id_input,
                                            p_json_input => v_json_output,
                                            p_report_date_input => v_rd,
                                            p_report_tag => C_REPORT_NAME_TAG,
                                            p_items_arr_tag => C_ITEMS_ARR_TAG,
                                            p_template_name => C_TEMPLATE_NAME,
                                            p_output_file_name => C_OUTPUT_FILE_NAME,
                                            p_s3_file_name => C_S3_FILE_NAME);

      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Построение отчёта успешно завершено: Сверка сделок: СОФР-Биржа, Валютный рынок', it_log.C_MSG_TYPE__DEBUG);
      RETURN v_json_output;

      EXCEPTION
          WHEN OTHERS THEN
              -- Если массив ошибок пустой, но мы всё равно сюда попали, значит произошло что-то непредвиденное
              it_error.put_error_in_stack;
              IF (v_errors_array.get_size() = 0) THEN
                  v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                          C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
              END IF;

              RETURN BuildJsonOutput(p_errors_array => v_errors_array);
  END CurrencyMarket_RC_ReportRun;

  -- Аналог string_to_table из пакета APEX_UTIL
  FUNCTION string_to_table(
    p_string IN VARCHAR2,
    p_delimiter IN VARCHAR2 := ','
  ) RETURN vc_arr2 IS
    v_arr vc_arr2;
    v_pos PLS_INTEGER;
    v_idx PLS_INTEGER := 1;
    v_str VARCHAR2(32767) := p_string;
  BEGIN
    IF p_string IS NULL THEN
      RETURN v_arr;
    END IF;

    LOOP
      v_pos := INSTR(v_str, p_delimiter);
      IF v_pos > 0 THEN
        v_arr(v_idx) := SUBSTR(v_str, 1, v_pos - 1);
        v_str := SUBSTR(v_str, v_pos + LENGTH(p_delimiter));
        v_idx := v_idx + 1;
      ELSE
        v_arr(v_idx) := v_str;
      EXIT;
      END IF;
    END LOOP;

  RETURN v_arr;
  END string_to_table;

  -------------------------------------------------------------------------------------------------------------
  ----- Парсинг биржевых файлов F04 и O04 (для сделок на срочном рынке) во временную таблицу DBDUI_F04_O04_FILE_DBT -----
  -------------------------------------------------------------------------------------------------------------
  FUNCTION ParseF04O04(p_trace_id_input VARCHAR2, p_csv CLOB,
                       p_type CHAR -- Тип биржевого файла (O - опционы, F - фьючерсы)
  )
      RETURN INTEGER
  IS
      -- Коллекция строк для пакетной вставки (по структуре таблицы dbdui_f04_o04_file_dbt)
      TYPE t_file IS TABLE OF dbdui_f04_o04_file_dbt%ROWTYPE;
      v_data    t_file := t_file();

      -- Переменные
      v_csv             CLOB;
      v_len             INTEGER;
      v_pos             INTEGER := 1; -- Текущая позиция в CLOB
      v_next_lb         INTEGER; -- Позиция следующего перевода строки
      v_line            VARCHAR2(32767);
      v_batch_rows_cnt  INTEGER := 0; -- Счётчик строк в батче
      v_rows_cnt        NUMBER := 0; -- Общее количество загруженных строк

      -- Индексы колонок
      v_index_id_deal   INTEGER;
      v_index_date      INTEGER;
      v_index_time      INTEGER;
      v_index_date_clr  INTEGER;
      v_index_kod_sell  INTEGER;
      v_index_kod_buy   INTEGER;
      v_index_price     INTEGER;
      v_index_vol       INTEGER;
      v_index_isin      INTEGER;

      v_header          VC_ARR2;
      v_fields          VC_ARR2;
      c_batch_size      CONSTANT INTEGER := 50; -- Число строк, которые гарантированно влезут в VARCHAR2 (эмпирическое значение)
  BEGIN
      -- Сообщение стоит включать исключительно для отладки, дабы не грузить базу сохранением лишних CLOB'ов
      --     it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Получен биржевой файл срочного рынка, парсинг запущен', it_log.C_MSG_TYPE__DEBUG, p_csv);
      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Получен биржевой файл срочного рынка, парсинг запущен', it_log.C_MSG_TYPE__DEBUG);

      -- Получаем заголовки
      v_csv := REPLACE(p_csv, CHR(13) || CHR(10), CHR(10));
      v_len := DBMS_LOB.getlength(v_csv);
      v_next_lb := DBMS_LOB.instr(v_csv, CHR(10), v_pos);
      v_line  := DBMS_LOB.substr(v_csv, v_next_lb - v_pos, v_pos);
      v_pos   := v_next_lb + 1;
      v_header := string_to_table(v_line, ';');

      -- Определяем индексы нужных колонок
      FOR i IN 1..v_header.COUNT LOOP
          CASE UPPER(v_header(i))
              WHEN 'ID_DEAL'  THEN v_index_id_deal := i;
              WHEN 'DATE'     THEN v_index_date := i;
              WHEN 'TIME'     THEN v_index_time := i;
              WHEN 'DATE_CLR' THEN v_index_date_clr := i;
              WHEN 'KOD_SELL' THEN v_index_kod_sell := i;
              WHEN 'KOD_BUY'  THEN v_index_kod_buy := i;
              WHEN 'PRICE'    THEN v_index_price := i;
              WHEN 'VOL'      THEN v_index_vol := i;
              WHEN 'ISIN'     THEN v_index_isin := i;
              ELSE NULL;
          END CASE;
      END LOOP;


      -- Читаем CLOB построчно, батчами по 50 строк
      WHILE v_pos <= v_len LOOP
          v_next_lb := DBMS_LOB.instr(v_csv, chr(10), v_pos);
          IF v_next_lb = 0 THEN
              v_line := DBMS_LOB.substr(v_csv, v_len - v_pos + 1, v_pos);
              v_pos  := v_len + 1; -- Парсинг завершён, выход за пределы файла для остановки на следующей итерации
          ELSE
              v_line := DBMS_LOB.substr(v_csv, v_next_lb - v_pos, v_pos);
              v_pos  := v_next_lb + 1;
          END IF;

          v_batch_rows_cnt := v_batch_rows_cnt + 1;

          -- Парсим строку
          v_fields := string_to_table(v_line, ';'); -- Разбиваем
          IF v_fields.COUNT = v_header.COUNT THEN -- Строка соответствует заголовкам
              v_data.EXTEND; -- Добавляем
              -- Заполняем
              v_data(v_data.LAST).t_code_m        := v_fields(v_index_id_deal);
              v_data(v_data.LAST).t_isin_m        := v_fields(v_index_isin);
              v_data(v_data.LAST).t_date_m        := TO_DATE(v_fields(v_index_date), 'YYYY/MM/DD');
              v_data(v_data.LAST).t_time_m        := TO_DATE(v_fields(v_index_time), 'HH24:MI:SS');
              v_data(v_data.LAST).t_date_clr_m    := TO_DATE(v_fields(v_index_date_clr), 'DD.MM.YYYY');
              v_data(v_data.LAST).t_client_code_m := COALESCE(v_fields(v_index_kod_sell), '') || COALESCE(v_fields(v_index_kod_buy), '');
              v_data(v_data.LAST).t_oper_m        :=
                  CASE
                      WHEN v_fields(v_index_kod_sell) IS NOT NULL THEN 'S'
                      WHEN v_fields(v_index_kod_buy)  IS NOT NULL THEN 'B'
                  END;
              v_data(v_data.LAST).t_price_m       := ToLocalNumber(v_fields(v_index_price));
              v_data(v_data.LAST).t_quantity_m    := ToLocalNumber(v_fields(v_index_vol));
              v_data(v_data.LAST).t_market_type   := p_type;
          END IF;


          -- Если набрали батч или достигли конца файла, сливаем
          IF v_batch_rows_cnt = c_batch_size OR v_pos > v_len THEN
              FORALL i IN v_data.FIRST .. v_data.LAST SAVE EXCEPTIONS
                  INSERT INTO dbdui_f04_o04_file_dbt VALUES v_data(i);

              v_rows_cnt := v_rows_cnt + v_data.COUNT;
              v_data.DELETE;
              v_batch_rows_cnt := 0;
          END IF;
      END LOOP;

      it_log.log('traceId=''' || p_trace_id_input || ''' ' ||
                 'Парсинг завершен, загружено строк: ' || v_rows_cnt,
                 it_log.C_MSG_TYPE__DEBUG);

      RETURN v_rows_cnt;

      EXCEPTION
        WHEN OTHERS THEN
            it_error.put_error_in_stack;
            RAISE_APPLICATION_ERROR(-20001, 'traceId=''' || p_trace_id_input || ''' ' || 'Ошибка парсинга CSV: ' || SQLERRM);
  END ParseF04O04;

  ---------------------------------------------------------------------------------------
  ----- Формирование UI Form для Отчёта Сверка сделок: СОФР-Биржа, Срочный рынок -----
  -------------------------------------------------------------------------------------
  FUNCTION DerivativesMarketReportMetaUI
      RETURN CLOB
  IS
      C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
      C_REPORT_LOCALIZED_NAME VARCHAR2(128) := 'Сверка сделок: СОФР-Биржа, Срочный рынок';
      C_SYS_TAGS              VARCHAR2(256) := '["ORACLE","Exchange"]';
      v_meta_ui               CLOB;
  BEGIN
      WITH
          deal_types(name, value) AS (
              SELECT 'Покупка', 'B' FROM dual
              UNION ALL
              SELECT 'Продажа', 'S' FROM dual
          )
      SELECT
          JSON_OBJECT(
              C_META_UI_TAG__ROLES   VALUE C_ROLES FORMAT JSON,
              C_META_UI_TAG__LABEL   VALUE C_REPORT_LOCALIZED_NAME,
              C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
              C_META_UI_TAG__FORM    VALUE JSON_ARRAY(
                  -- Первая строка
                  JSON_ARRAY(
                      JSON_OBJECT(
                          'label'    VALUE 'Дата сделки',
                          'name'     VALUE 'reportDate',
                          'type'     VALUE 'date',
                          'required' VALUE 'true' FORMAT JSON,
                          'column'   VALUE 0,
                          'default'  VALUE TO_CHAR(sysdate, 'YYYY-MM-DD')
                          RETURNING CLOB
                      ),
                      JSON_OBJECT(
                          'label'    VALUE 'ЕКК клиента',
                          'name'     VALUE 'clientCode',
                          'type'     VALUE 'text',
                          'required' VALUE 'false' FORMAT JSON,
                          'column'   VALUE 1,
                          'default'  VALUE ''
                          RETURNING CLOB
                      ),
                      JSON_OBJECT(
                          'label'    VALUE 'Направление сделки',
                          'name'     VALUE 'dealType',
                          'type'     VALUE 'select',
                          'required' VALUE 'true' FORMAT JSON,
                          'column'   VALUE 2,
                          'default'  VALUE (
                              SELECT JSON_ARRAYAGG(VALUE RETURNING CLOB)
                              FROM deal_types
                          ),
                          'multiselect' VALUE 'true' FORMAT JSON,
                          'items'       VALUE (
                              SELECT JSON_ARRAYAGG(
                                         JSON_OBJECT(
                                             'name'  VALUE name,
                                             'value' VALUE VALUE
                                         ) RETURNING CLOB
                                     )
                              FROM deal_types
                          )
                          RETURNING CLOB
                      )
                  ),
                  -- Вторая строка
                  JSON_ARRAY(
                      JSON_OBJECT(
                          'label'    VALUE 'Номер сделки',
                          'name'     VALUE 'dealNum',
                          'type'     VALUE 'text',
                          'required' VALUE 'false' FORMAT JSON,
                          'column'   VALUE 0,
                          'default'  VALUE ''
                          RETURNING CLOB
                      ),
                      JSON_OBJECT(
                          'label'    VALUE 'ФИО клиента',
                          'name'     VALUE 'clientName',
                          'type'     VALUE 'text',
                          'required' VALUE 'false' FORMAT JSON,
                          'column'   VALUE 1,
                          'default'  VALUE ''
                          RETURNING CLOB
                      ),
                      JSON_OBJECT(
                          'label'    VALUE 'Тикер бумаги',
                          'name'     VALUE 'ticker',
                          'type'     VALUE 'text',
                          'required' VALUE 'false' FORMAT JSON,
                          'column'   VALUE 2,
                          'default'  VALUE ''
                          RETURNING CLOB
                      )
                  )
              ) RETURNING CLOB
          )
      INTO v_meta_ui
      FROM dual;

      RETURN v_meta_ui;
  END DerivativesMarketReportMetaUI;

  FUNCTION ClearTmpF04O04
    RETURN INTEGER
  IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    DELETE FROM dbdui_f04_o04_file_dbt;
    COMMIT;
    RETURN 1;
  END;

  ------------------------------------------------------------------------------------------
  ----- Формирование Отчёта сравнения данных СОФР с биржевыми файлами (срочный рынок) -----
  ------------------------------------------------------------------------------------------
  FUNCTION DerivativesMarket_RC_ReportRun(p_trace_id_input VARCHAR2,
                                          p_json_input CLOB,
                                          p_is_production CHAR DEFAULT '1' -- Флаг для режима прода
  )
      RETURN CLOB
  IS
      -- Константы
      C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := 'sofr_market_f04_o04';
      C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Сверка_СОФР-биржа_срочный_рынок';
      C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := 'derivativesmarket_report';
      C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'GetDerivativesMarket';
      C_ITEMS_F_ARR_TAG       CONSTANT VARCHAR2(128) := 'deals'; -- сделки по фьючерсам
      C_ITEMS_OP_ARR_TAG      CONSTANT VARCHAR2(128) := 'deals_op'; -- сделки по опционам

      -- Входной JSON
      C_IN_REPORT_DATE_TAG    CONSTANT VARCHAR2(32) := 'reportDate';
      C_IN_CLIENT_CODE_TAG    CONSTANT VARCHAR2(32) := 'clientCode';
      C_IN_CLIENT_NAME_TAG    CONSTANT VARCHAR2(32) := 'clientName';
      C_IN_DEAL_TYPE_TAG      CONSTANT VARCHAR2(32) := 'dealType';
      C_IN_DEAL_NUM_TAG       CONSTANT VARCHAR2(32) := 'dealNum';
      C_IN_TICKER_TAG         CONSTANT VARCHAR2(32) := 'ticker';
      C_IN_DATE_FORMAT        CONSTANT VARCHAR2(32) := 'YYYY-MM-DD';

      -- Константы - Ошибки
      C_ERR_03_CODE           CONSTANT VARCHAR2(8)   := 'ER_03';
      C_ERR_03_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: клиент по ЕКК=''%s'' не найден';
      C_ERR_04_CODE           CONSTANT VARCHAR2(8)   := 'ER_04';
      C_ERR_04_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: клиент по ФИО=''%s'' не найден';
      C_ERR_05_CODE           CONSTANT VARCHAR2(8)   := 'ER_05';
      C_ERR_05_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: номер сделки=''%s'' не найден';
      C_ERR_06_CODE           CONSTANT VARCHAR2(8)   := 'ER_06';
      C_ERR_06_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: тикер бумаги=''%s'' не найден';
      C_ERR_99_CODE           CONSTANT VARCHAR2(8)   := 'ER_99';
      C_ERR_99_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: другая ошибка';

      -- Параметры входного запроса
      v_rd                    DATE;                 -- Дата отчёта
      v_client_code           VARCHAR2(64);         -- ЕКК клиента
      v_client_name           VARCHAR2(120);        -- ФИО или часть ФИО клиента
      v_deal_num              VARCHAR2(30);         -- № сделки
      v_deal_type_list        SYS.ODCIVARCHAR2LIST; -- Направление сделки
      v_ticker                VARCHAR2(30);         -- Тикер бумаги
      v_market_files_opt_obj  JSON_OBJECT_T;        -- Объект Биржевых файлов: опционы
      v_market_files_fut_obj  JSON_OBJECT_T;        -- Объект Биржевых файлов: фьючерсы

      -- Переменные
      v_json_obj                 JSON_OBJECT_T;
      v_has_args                 BOOLEAN := FALSE;
      v_json_output              CLOB;
      v_json_futures             CLOB;
      v_json_options             CLOB;
      v_dummy_arr                CLOB;
      v_doc_fact_headers         CLOB; -- Header'ы для Фабрики документов
      v_inserted_rows            INTEGER := 0;
      v_futures_length           INTEGER;
      v_options_length           INTEGER;
      v_dest_offset              INTEGER;
      v_exMeta_arr               JSON_ARRAY_T := JSON_ARRAY_T();
      v_is_clear                 INTEGER;
      v_sql                      VARCHAR2(2048);
      v_tmp_clob                 CLOB;

      -- Валидация
      v_is_ekk_exists            CHAR(1)      := '0'; -- 1 - если ЕКК найден в СОФР или QUIK, иначе - 0
      v_is_fio_exists            CHAR(1)      := '0'; -- 1 - если ФИО найден в СОФР, иначе - 0
      v_is_deal_num_exists       CHAR(1)      := '0'; -- 1 - если сделка с указанным номером найдена в СОФР или Биржевом файле, иначе - 0
      v_is_ticker_exists         CHAR(1)      := '0'; -- 1 - если сделка с указанным тикером найдена в СОФР или Биржевом файле, иначе - 0
      v_market_files_opt_has_err BOOLEAN := FALSE;
      v_market_files_fut_has_err BOOLEAN := FALSE;
      v_files_opt_err_msg_obj    JSON_OBJECT_T;
      v_files_fut_err_msg_obj    JSON_OBJECT_T;
      v_errors_array             JSON_ARRAY_T := JSON_ARRAY_T();
  BEGIN
      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Сверка СОФР-Биржа, Срочный рынок', it_log.C_MSG_TYPE__DEBUG);

      -- Парсим входной JSON, предварительно исключив массивы с содержимым биржевых файлов
      v_sql := '
        SELECT JSON_TRANSFORM(:j, REMOVE ''' || C_MARKET_FILE_JPATH__OPTIONS || ''',
                                  REMOVE ''' || C_MARKET_FILE_JPATH__FUTURES || ''')
        FROM dual';
      EXECUTE IMMEDIATE v_sql INTO v_tmp_clob USING p_json_input;
      v_json_obj := JSON_OBJECT_T.PARSE(v_tmp_clob);

      v_rd := TO_DATE(v_json_obj.get_string(C_IN_REPORT_DATE_TAG), C_IN_DATE_FORMAT);
      v_client_code := UPPER(v_json_obj.get_string(C_IN_CLIENT_CODE_TAG));
      v_client_name := UPPER(v_json_obj.get_string(C_IN_CLIENT_NAME_TAG));
      v_deal_num := UPPER(v_json_obj.get_string(C_IN_DEAL_NUM_TAG));
      v_ticker := UPPER(v_json_obj.get_string(C_IN_TICKER_TAG));
      v_deal_type_list := GetArrayFromJsonField(p_json_input, C_IN_DEAL_TYPE_TAG);
      v_market_files_opt_obj := v_json_obj.get_object(C_MARKET_FILE_TAG__OPTIONS);
      v_market_files_fut_obj := v_json_obj.get_object(C_MARKET_FILE_TAG__FUTURES);

      -- Если нет даты, отдаем мета-данные формы
      v_has_args := v_rd IS NOT NULL;
      IF NOT v_has_args THEN
        it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Дата отчёта не указана, возвращаем Meta UI формы: Сверка СОФР-Биржа, Срочный рынок', it_log.C_MSG_TYPE__DEBUG);
        RETURN BuildJsonOutput(p_exmeta_array => AddCamelToExMetaArr(v_exMeta_arr, C_DERIVATIVES_M_CAMEL_ROUTEID, C_DERIVATIVES_M_CAMEL_SCRIPT),
                               p_body => DerivativesMarketReportMetaUI());
      END IF;

      -- Проверяем наличие биржевых файлов
      v_files_opt_err_msg_obj := GetMarketFileErrObj(p_trace_id_input, v_rd, 'DD.MM.YYYY', v_market_files_opt_obj);
      v_files_fut_err_msg_obj := GetMarketFileErrObj(p_trace_id_input, v_rd, 'DD.MM.YYYY', v_market_files_fut_obj);
      v_market_files_opt_has_err := v_files_opt_err_msg_obj IS NOT NULL;
      v_market_files_fut_has_err := v_files_fut_err_msg_obj IS NOT NULL;
      -- Должен быть хотя бы один валидный объект биржевых файлов: опционы или фьючерсы
      IF (v_market_files_opt_has_err AND v_market_files_fut_has_err) THEN
        v_market_files_opt_has_err := AppendIfNotNull(v_errors_array, v_files_opt_err_msg_obj);
        v_market_files_fut_has_err := AppendIfNotNull(v_errors_array, v_files_fut_err_msg_obj);
      END IF;

      IF (p_is_production = 0) THEN
        it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Парсинг входных параметров завершен: Сверка СОФР-Биржа, Срочный рынок', it_log.C_MSG_TYPE__DEBUG,
                   'Параметры отчёта: ' ||
                   'report_date=' || TO_CHAR(v_rd, 'YYYY-MM-DD')     || ', ' ||
                   'client_code=' || COALESCE(v_client_code, 'NULL') || ', ' ||
                   'client_name=' || COALESCE(v_client_name, 'NULL') || ', ' ||
                   'ticker='      || COALESCE(v_ticker, 'NULL')      || ', ' ||
                   'deal_num='    || COALESCE(v_deal_num, 'NULL')    || ', ' ||
                   'deal_type_list_count=' || CASE
                                                WHEN v_deal_type_list IS NULL THEN '0'
                                                ELSE TO_CHAR(v_deal_type_list.COUNT)
                                              END || ', ' ||
                   'futures_market_files_has_error=' || CASE
                                                          WHEN v_market_files_opt_has_err THEN 'TRUE'
                                                          ELSE 'FALSE'
                                                        END || ', ' ||
                   'options_market_files_has_error=' || CASE
                                                          WHEN v_market_files_fut_has_err THEN 'TRUE'
                                                          ELSE 'FALSE'
                                                        END);
      END IF;

      -- Валидация входных параметров
      -- В СОФР или Биржевом файле найдены сделки с указанными ЕКК
      SELECT
          CASE
              WHEN v_client_code IS NULL OR v_client_code = '' THEN 1
              WHEN EXISTS (SELECT 1 FROM ddlcontrmp_dbt sofr WHERE sofr.t_mpcode = v_client_code) THEN 1
              WHEN EXISTS (SELECT 1 FROM dbdui_f04_o04_file_dbt market_file WHERE market_file.t_client_code_m = v_client_code) THEN 1
              ELSE 0
          END
      INTO v_is_ekk_exists
      FROM dual;

      -- В СОФР существует клиент с введенным ФИО
      SELECT
          CASE
              WHEN v_client_name IS NULL OR v_client_name = '' THEN 1
              WHEN EXISTS (SELECT 1 FROM dparty_dbt cl WHERE UPPER(cl.t_name) LIKE '%' || v_client_name || '%') THEN 1
              ELSE 0
          END
      INTO v_is_fio_exists
      FROM dual;

      -- В СОФР или биржевом файле существует сделка с указанным номером
      SELECT
          CASE
              WHEN v_deal_num IS NULL OR v_deal_num = '' THEN 1
              WHEN EXISTS (SELECT 1 FROM dbdui_f04_o04_file_dbt mf WHERE mf.t_code_m = v_deal_num) THEN 1
              WHEN EXISTS (SELECT 1 FROM ddvdeal_dbt sofr WHERE UPPER(substr(sofr.t_code,-19)) = v_deal_num) THEN 1
              ELSE 0
          END
      INTO v_is_deal_num_exists
      FROM dual;

      -- В СОФР или биржевом файле существует сделка с указанным тикером
      SELECT
          CASE
              WHEN v_ticker IS NULL OR v_ticker = '' THEN 1
              WHEN EXISTS (SELECT 1 FROM dbdui_f04_o04_file_dbt mf WHERE mf.t_isin_m = v_ticker) THEN 1
              WHEN EXISTS (SELECT 1 FROM dobjcode_dbt sofr WHERE sofr.t_codekind = 11 AND sofr.t_code = v_ticker) THEN 1
              ELSE 0
          END
      INTO v_is_ticker_exists
      FROM dual;

      IF (v_is_ekk_exists = '0') THEN
          v_errors_array.append(GetErrorObjAndLog(p_trace_id_input,C_ERR_03_CODE,
                                                  UTL_LMS.FORMAT_MESSAGE(C_ERR_03_MSG, v_client_code)));
      END IF;
      IF (v_is_fio_exists = '0') THEN
          v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_04_CODE,
                                                  UTL_LMS.FORMAT_MESSAGE(C_ERR_04_MSG, v_client_name)));
      END IF;
      IF (v_is_deal_num_exists = '0') THEN
          v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_05_CODE,
                                                  UTL_LMS.FORMAT_MESSAGE(C_ERR_05_MSG, v_deal_num)));
      END IF;
      IF (v_is_ticker_exists = '0') THEN
          v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_06_CODE,
                                                  UTL_LMS.FORMAT_MESSAGE(C_ERR_06_MSG, v_ticker)));
      END IF;

      IF v_errors_array.get_size() > 0 THEN
          RAISE NO_DATA_FOUND;
      END IF;

      -- Парсим биржевые файлы
      SELECT ClearTmpF04O04 INTO v_is_clear FROM dual; -- Очистим временную таблицу, на случай, если там что-то есть
      IF NOT v_market_files_opt_has_err THEN
        v_inserted_rows := v_inserted_rows + ParseMarketFiles(p_trace_id_input, p_json_input, C_MARKET_FILE_TAG__OPTIONS, C_MARKET_FILE_JPATH__OPTIONS);
      END IF;
      IF NOT v_market_files_fut_has_err THEN
        v_inserted_rows := v_inserted_rows + ParseMarketFiles(p_trace_id_input, p_json_input, C_MARKET_FILE_TAG__FUTURES, C_MARKET_FILE_JPATH__FUTURES);
      END IF;

      -- Генерация JSON отчёта
      WITH
          client_m AS (SELECT dbo.t_id, dbo.t_mpcode, contr.t_partyid, contr.t_name
                       FROM ddlcontrmp_dbt dbo
                           LEFT JOIN (SELECT contr.t_partyid, contr.t_id, contr.t_name FROM dsfcontr_dbt contr) contr
                               ON contr.t_id = dbo.t_sfcontrid
          ),
          tic AS (SELECT t.t_code, t.t_objectid -- Тикер может меняться со временем, поэтому необходимо выбрать тот, который был актуален на дату построения отчёта
                  FROM dobjcode_dbt t
                  WHERE t.t_codekind = 11
                    AND t.t_bankdate <= v_rd + 1 -- IMPROVE: вероятно, лютый костыль: почему-то дата начала тикера t_bankdate может оказаться на 1 день позже самой даты сделки
                    AND (t.t_bankclosedate > v_rd + 1 -- IMPROVE: вероятно, лютый костыль: почему-то дата начала тикера t_bankdate может оказаться на 1 день позже самой даты сделки
                      OR t.t_bankclosedate = DATE '0001-01-01') -- Спец дата, если тикер действующий в настоящее время
          ),
          result AS (
              SELECT
                  market_file.t_code_m                                                       AS t_code_m,        -- Внешний номер сделки из биржевого файла
                  UPPER(substr(sofr.t_code,-19))                                             AS t_code_s,        -- Внешний номер сделки из БД СОФР
                  market_file.t_date_m                                                       AS t_date_m,        -- Дата сделки биржа
                  sofr.t_date                                                                AS t_date_s,        -- Дата сделки СОФР
                  market_file.t_time_m                                                       AS t_time_m,        -- Время сделки биржа
                  sofr.t_date + (sofr.t_time - TRUNC(sofr.t_time))                           AS t_time_s,        -- Время сделки СОФР
                  market_file.t_date_clr_m                                                   AS t_date_clr_m,    -- Дата клиринга биржа
                  sofr.t_date_clr                                                            AS t_date_clr_s,    -- Дата клиринга СОФР
                  market_file.t_client_code_m                                                AS t_client_code_m, -- ЕКК клиента биржа
                  mar_code.t_mpcode                                                          AS t_client_code_s, -- ЕКК клиента СОФР
                  client_m.t_name                                                            AS t_client_name_m, -- Клиент биржа
                  client_s.t_name                                                            AS t_client_name_s, -- Клиент СОФР
                  market_file.t_isin_m                                                       AS t_isin_m,        -- Уникальный тикер бумаги биржа
                  tic.t_code                                                                 AS t_isin_s,        -- Уникальный тикер бумаги СОФР
                  market_file.t_oper_m                                                       AS t_oper_m,        -- Вид сделки биржа
                  CASE
                      WHEN UPPER(opr.t_name) LIKE '%ПОКУПКА%' THEN 'B'
                      WHEN UPPER(opr.t_name) LIKE '%ПРОДАЖА%' THEN 'S'
                      ELSE opr.t_name
                  END                                                                        AS t_oper_s,        -- Вид сделки СОФР
                  market_file.t_quantity_m                                                   AS t_quantity_m,    -- Кол-во биржа
                  sofr.t_amount                                                              AS t_quantity_s,    -- Кол-во СОФР
                  market_file.t_price_m                                                      AS t_price_m,       -- Цена биржа
                  ROUND(CASE
                            WHEN LOWER(opr.t_name) LIKE '%опцион%' THEN sofr.t_bonus
                            WHEN LOWER(opr.t_name) LIKE '%фьючерс%' THEN sofr.t_price
                        END, 4)                                                              AS t_price_s,       -- Цена СОФР
                  COALESCE(dog.t_number, rsb_secur.getdealsfcontrnumber(sofr.t_clientcontr)) AS t_dog,           -- Номер договора СОФР
                  market_file.t_market_type                                                  AS t_market_type    -- Тип файла из которого пришла сделка: O - файл с опционами, F - файл с фьючерсами
              FROM dbdui_f04_o04_file_dbt market_file
                       LEFT JOIN ddvdeal_dbt sofr -- Таблица со сделками
                                 ON market_file.t_code_m = UPPER(substr(sofr.t_code,-19))
                       LEFT JOIN doprkoper_dbt opr -- Расшифровка направления сделки
                                 ON sofr.t_kind = opr.t_kind_operation
                       LEFT JOIN dparty_dbt client_s -- Субъекты экономики (СОФР)
                                 ON sofr.t_client = client_s.t_partyid
                       LEFT JOIN client_m -- Субъекты экономики (Биржа)
                                 ON client_m.t_mpcode = market_file.t_client_code_m
                       LEFT JOIN dsfcontr_dbt dog -- Номер договора
                                 ON sofr.t_clientcontr = dog.t_id
                       LEFT JOIN ddlcontrmp_dbt mar_code -- Короткий ЕКК клиента на бирже
                                 ON mar_code.t_sfcontrid = dog.t_id
                       LEFT JOIN dfininstr_dbt tagfi -- Информация о финансовом инструменте
                                 ON tagfi.t_fiid = sofr.t_fiid
                       LEFT JOIN tic -- Наименование уникального тикета сделки
                                 ON tic.t_objectid = tagfi.t_fiid
              WHERE 1=1
                AND (v_client_code IS NULL OR v_client_code = '' OR market_file.t_client_code_m = v_client_code)
                AND (v_client_name IS NULL OR v_client_name = '' OR UPPER(client_m.t_name) LIKE '%'|| v_client_name || '%')
                AND (v_deal_num IS NULL OR v_deal_num = '' OR UPPER(market_file.t_code_m) = v_deal_num)
                AND (v_ticker IS NULL OR v_ticker = '' OR UPPER(market_file.t_isin_m) = v_ticker)
                AND (NOT EXISTS (SELECT 1 FROM TABLE(v_deal_type_list))
                  OR market_file.t_oper_m IN (SELECT COLUMN_VALUE FROM TABLE(v_deal_type_list)))
          )
      -- Строим напрямую через SQL JSON, а не PL/SQL JSON Object Types для экономии ресурсов
      SELECT
          (SELECT (
              JSON_ARRAYAGG(
                  JSON_OBJECT(
                      'code_m'        VALUE t_code_m,
                      'code_s'        VALUE t_code_s,
                      'date_m'        VALUE t_date_m,
                      'date_s'        VALUE t_date_s,
                      'time_m'        VALUE t_time_m,
                      'time_s'        VALUE t_time_s,
                      'date_clr_m'    VALUE t_date_clr_m,
                      'date_clr_s'    VALUE t_date_clr_s,
                      'client_code_m' VALUE t_client_code_m,
                      'client_code_s' VALUE t_client_code_s,
                      'client_name_m' VALUE t_client_name_m,
                      'client_name_s' VALUE t_client_name_s,
                      'isin_m'        VALUE t_isin_m,
                      'isin_s'        VALUE t_isin_s,
                      'deal_type_m'   VALUE t_oper_m,
                      'deal_type_s'   VALUE t_oper_s,
                      'quantity_m'    VALUE t_quantity_m,
                      'quantity_s'    VALUE t_quantity_s,
                      'price_m'       VALUE t_price_m,
                      'price_s'       VALUE t_price_s,
                      'no_dog_s'      VALUE t_dog
                  ) RETURNING CLOB
              )
          )
          FROM (
              SELECT r.*
              FROM result r
              WHERE r.t_market_type = 'F'
              UNION ALL
              -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
              SELECT NULL, NULL, NULL, NULL, NULL, NULL,
                     NULL, NULL, NULL, NULL,
                     NULL, NULL, NULL, NULL, NULL,
                     NULL, NULL, NULL, NULL, NULL, NULL, 'F'
              FROM dual
              WHERE NOT EXISTS (SELECT 1 FROM result r WHERE r.t_market_type = 'F')
          )),
          (SELECT (
              JSON_ARRAYAGG(
                  JSON_OBJECT(
                      'code_m'        VALUE t_code_m,
                      'code_s'        VALUE t_code_s,
                      'date_m'        VALUE t_date_m,
                      'date_s'        VALUE t_date_s,
                      'time_m'        VALUE t_time_m,
                      'time_s'        VALUE t_time_s,
                      'date_clr_m'    VALUE t_date_clr_m,
                      'date_clr_s'    VALUE t_date_clr_s,
                      'client_code_m' VALUE t_client_code_m,
                      'client_code_s' VALUE t_client_code_s,
                      'client_name_m' VALUE t_client_name_m,
                      'client_name_s' VALUE t_client_name_s,
                      'isin_m'        VALUE t_isin_m,
                      'isin_s'        VALUE t_isin_s,
                      'deal_type_m'   VALUE t_oper_m,
                      'deal_type_s'   VALUE t_oper_s,
                      'quantity_m'    VALUE t_quantity_m,
                      'quantity_s'    VALUE t_quantity_s,
                      'price_m'       VALUE t_price_m,
                      'price_s'       VALUE t_price_s,
                      'no_dog_s'      VALUE t_dog
                  ) RETURNING CLOB
              )
          )
          FROM (
              SELECT r.*
              FROM result r
              WHERE r.t_market_type = 'O'
              UNION ALL
              -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
              SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                     NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                     NULL, NULL, NULL, NULL, 'O'
              FROM dual
              WHERE NOT EXISTS (SELECT 1 FROM result r WHERE r.t_market_type = 'O')
          )
          )
      INTO v_json_futures, v_json_options
      FROM dual;

      IF DBMS_LOB.GETLENGTH(v_json_futures) + DBMS_LOB.GETLENGTH(v_json_options) <= C_MAX_DATA_SIZE_PER_PART THEN
          -- Если укладываемся в размеры, строим вручную
          v_doc_fact_headers := GetDocFactHeaders(p_trace_id_input,
                                                  v_rd,
                                                  C_TEMPLATE_NAME,
                                                  C_OUTPUT_FILE_NAME,
                                                  C_S3_FILE_NAME);
          SELECT JSON_ARRAY(
              JSON_OBJECT(
                  C_OUTPUT_TAG__EXMETA VALUE '[]' FORMAT JSON, -- сюда потом будем класть что-нибудь полезное
                  C_OUTPUT_TAG__HEADERS VALUE v_doc_fact_headers FORMAT JSON,
                  C_OUTPUT_TAG__BODY VALUE JSON_OBJECT(
                      'GetDerivativesMarket' VALUE JSON_OBJECT(
                          'date' VALUE TO_CHAR(v_rd, 'DD.MM.YYYY'), -- формальная дата отчёта
                          'deals' VALUE v_json_futures FORMAT JSON,
                          'deals_op' VALUE v_json_options FORMAT JSON
                      ) RETURNING CLOB
                  ) RETURNING CLOB
              ) RETURNING CLOB
          )
          INTO v_json_output
          FROM dual;
      ELSE
          -- Если данных много, бьём поочерёдно один из массивов (фьючерсы, опционы), а вместо второго подкидываем заглушку для Jasper'а
          SELECT (
              JSON_ARRAYAGG(
                  JSON_OBJECT(
                      'code_m'        VALUE NULL,
                      'code_s'        VALUE NULL,
                      'date_m'        VALUE NULL,
                      'date_s'        VALUE NULL,
                      'time_m'        VALUE NULL,
                      'time_s'        VALUE NULL,
                      'date_clr_m'    VALUE NULL,
                      'date_clr_s'    VALUE NULL,
                      'client_code_m' VALUE NULL,
                      'client_code_s' VALUE NULL,
                      'client_name_m' VALUE NULL,
                      'client_name_s' VALUE NULL,
                      'isin_m'        VALUE NULL,
                      'isin_s'        VALUE NULL,
                      'deal_type_m'   VALUE NULL,
                      'deal_type_s'   VALUE NULL,
                      'quantity_m'    VALUE NULL,
                      'quantity_s'    VALUE NULL,
                      'price_m'       VALUE NULL,
                      'price_s'       VALUE NULL,
                      'no_dog_s'      VALUE NULL
                  ) RETURNING CLOB
              )
          )
          INTO v_dummy_arr
          FROM dual;

          v_json_futures := BuildDerivativesSplitJsonOutput(p_trace_id_input => p_trace_id_input,
                                                           p_json_input => v_json_futures,
                                                           p_report_date_input => v_rd,
                                                           p_report_tag => C_REPORT_NAME_TAG,
                                                           p_items_arr_tag => C_ITEMS_F_ARR_TAG,
                                                           p_template_name => C_TEMPLATE_NAME,
                                                           p_output_file_name => C_OUTPUT_FILE_NAME,
                                                           p_s3_file_name => C_S3_FILE_NAME,
                                                           p_dummy_items_arr_tag => v_dummy_arr,
                                                           p_dummy_items_arr => C_ITEMS_OP_ARR_TAG);

          v_json_options := BuildDerivativesSplitJsonOutput(p_trace_id_input => p_trace_id_input,
                                                           p_json_input => v_json_options,
                                                           p_report_date_input => v_rd,
                                                           p_report_tag => C_REPORT_NAME_TAG,
                                                           p_items_arr_tag => C_ITEMS_OP_ARR_TAG,
                                                           p_template_name => C_TEMPLATE_NAME,
                                                           p_output_file_name => C_OUTPUT_FILE_NAME,
                                                           p_s3_file_name => C_S3_FILE_NAME,
                                                           p_dummy_items_arr_tag => v_dummy_arr,
                                                           p_dummy_items_arr => C_ITEMS_F_ARR_TAG);

          DBMS_LOB.CREATETEMPORARY(v_json_output, FALSE);

          v_futures_length := DBMS_LOB.GETLENGTH(v_json_futures);
          v_options_length := DBMS_LOB.GETLENGTH(v_json_options);

          -- Копируем фьючерсы без последней скобки ']'
          DBMS_LOB.COPY(v_json_output, v_json_futures, v_futures_length - 1, 1, 1);

          -- Добавляем запятую
          DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');

          v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
          -- Копируем опционы без первой '['
          DBMS_LOB.COPY(v_json_output, v_json_options, v_options_length - 1, v_dest_offset, 2);

      END IF;

      RETURN v_json_output;

      EXCEPTION
          WHEN OTHERS THEN
              -- Если массив ошибок пустой, но мы всё равно сюда попали, значит произошло что-то непредвиденное
              it_error.put_error_in_stack;
              IF (v_errors_array.get_size() = 0) THEN
                  v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                          C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
              END IF;

              RETURN BuildJsonOutput(p_errors_array => v_errors_array);
  END DerivativesMarket_RC_ReportRun;

  -------------------------------------------------------------------------------------
  ----- Формирование UI Form для Отчёта Сверка сделок: СОФР-Биржа, Все рынки -----
  -------------------------------------------------------------------------------------
  FUNCTION AllMarketReportMetaUI
      RETURN CLOB
  IS
      C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
      C_REPORT_LOCALIZED_NAME VARCHAR2(128) := 'Сверка сделок: СОФР-Биржа, Все рынки';
      C_SYS_TAGS              VARCHAR2(256) := '["ORACLE","Exchange"]';
      v_meta_ui               CLOB;
  BEGIN
      SELECT
          JSON_OBJECT(
              C_META_UI_TAG__ROLES   VALUE C_ROLES FORMAT JSON,
              C_META_UI_TAG__LABEL   VALUE C_REPORT_LOCALIZED_NAME,
              C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
              C_META_UI_TAG__FORM    VALUE JSON_ARRAY(
                  -- Первая строка
                  JSON_ARRAY(
                      JSON_OBJECT(
                          'label'    VALUE 'Дата сделки',
                          'name'     VALUE 'reportDate',
                          'type'     VALUE 'date',
                          'required' VALUE 'true' FORMAT JSON,
                          'column'   VALUE 0,
                          'default'  VALUE TO_CHAR(sysdate, 'YYYY-MM-DD')
                          RETURNING CLOB
                      ),
                      JSON_OBJECT(
                          'label'    VALUE 'ЕКК клиента',
                          'name'     VALUE 'clientCode',
                          'type'     VALUE 'text',
                          'required' VALUE 'false' FORMAT JSON,
                          'column'   VALUE 1,
                          'default'  VALUE ''
                          RETURNING CLOB
                      )
                  ),
                  -- Вторая строка
                  JSON_ARRAY(
                      JSON_OBJECT(
                          'label'    VALUE 'ФИО клиента',
                          'name'     VALUE 'clientName',
                          'type'     VALUE 'text',
                          'required' VALUE 'false' FORMAT JSON,
                          'column'   VALUE 0,
                          'default'  VALUE ''
                          RETURNING CLOB
                      )
                  )
              ) RETURNING CLOB
          )
      INTO v_meta_ui
      FROM dual;

      RETURN v_meta_ui;
  END AllMarketReportMetaUI;

  ------------------------------------------------------------------------------------------
  ----- Формирование Отчёта сравнения данных СОФР с биржевыми файлами (срочный рынок) -----
  ------------------------------------------------------------------------------------------
  FUNCTION AllMarket_RC_ReportRun(p_trace_id_input VARCHAR2,
                                  p_json_input CLOB,
                                  p_is_production CHAR DEFAULT '1' -- Флаг для режима прода
  )
      RETURN CLOB
  IS
      -- Входной JSON
      C_IN_REPORT_DATE_TAG    CONSTANT VARCHAR2(32) := 'reportDate';
      C_IN_DATE_FORMAT        CONSTANT VARCHAR2(32) := 'YYYY-MM-DD';

      -- Константы - Ошибки
      C_ERR_99_CODE           CONSTANT VARCHAR2(8)   := 'ER_99';
      C_ERR_99_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: другая ошибка';

      -- Параметры входного запроса
      v_json_obj              JSON_OBJECT_T;
      v_rd                    DATE; -- Дата отчёта
      v_has_args              BOOLEAN := FALSE;

      -- Переменные
      v_stock_report          CLOB;
      v_currency_report       CLOB;
      v_derivatives_report    CLOB;
      v_stock_length          INTEGER;
      v_currency_length       INTEGER;
      v_derivatives_length    INTEGER;
      v_dest_offset           INTEGER;
      v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
      v_exMeta_arr            JSON_ARRAY_T := JSON_ARRAY_T();

      v_json_output           CLOB;
  BEGIN
      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Сверка остатков: СОФР-Биржа, Все рынки', it_log.C_MSG_TYPE__DEBUG);

      -- Парсим входной JSON
      v_json_obj := JSON_OBJECT_T.parse(p_json_input);
      v_rd := TO_DATE(v_json_obj.get_string(C_IN_REPORT_DATE_TAG), C_IN_DATE_FORMAT);
      v_has_args := v_rd IS NOT NULL;

      -- Если нет даты, отдаем мета-данные формы
      IF NOT v_has_args THEN
          RETURN BuildJsonOutput(p_exmeta_array => AddCamelToExMetaArr(v_exMeta_arr, C_ALL_M_CAMEL_ROUTEID, C_ALL_M_CAMEL_SCRIPT),
                                 p_body => AllMarketReportMetaUI());
      END IF;

      DBMS_LOB.CREATETEMPORARY(v_json_output, FALSE);
      v_stock_report := StockMarket_RC_ReportRun(p_trace_id_input, p_json_input, p_is_production);
      v_currency_report := CurrencyMarket_RC_ReportRun(p_trace_id_input, p_json_input, p_is_production);
      v_derivatives_report := DerivativesMarket_RC_ReportRun(p_trace_id_input, p_json_input, p_is_production);

      v_stock_length := DBMS_LOB.GETLENGTH(v_stock_report);
      v_currency_length := DBMS_LOB.GETLENGTH(v_currency_report);
      v_derivatives_length := DBMS_LOB.GETLENGTH(v_derivatives_report);

      -- Копируем StockReport без последней скобки ']'
      DBMS_LOB.COPY(v_json_output, v_stock_report, v_stock_length - 1, 1, 1);

      -- Добавляем запятую
      DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');

      v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
      -- Копируем CurrencyReport без первой '[' и без последней скобки ']'
      DBMS_LOB.COPY(v_json_output, v_currency_report, v_currency_length - 2, v_dest_offset, 2);

      -- Добавляем запятую
      DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');

      v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
      -- Копируем DerivativesReport без первой '['
      DBMS_LOB.COPY(v_json_output, v_derivatives_report, v_derivatives_length - 1, v_dest_offset, 2);

      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Построение отчёта успешно завершено: Сверка остатков: СОФР-Биржа, Все рынки', it_log.C_MSG_TYPE__DEBUG);
      RETURN v_json_output;

  EXCEPTION
      WHEN OTHERS THEN
          -- Освобождаем ресурсы
          IF DBMS_LOB.ISTEMPORARY(v_json_output) = 1 THEN
              DBMS_LOB.FREETEMPORARY(v_json_output);
          END IF;

          -- Если мы сюда попали, значит произошло что-то непредвиденное
          it_error.put_error_in_stack;
          IF (v_errors_array.get_size() = 0) THEN
              v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                      C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
          END IF;

          RETURN BuildJsonOutput(p_errors_array => v_errors_array);
  END AllMarket_RC_ReportRun;


  /**************************************************************************************************\
  [Конец блока] BIQ-23781.2(intech), BIQ-29457.2(avt) Расхождениях параметров сделок в СОФР с параметрами из биржевых файлов
  \**************************************************************************************************/


   /************************************************************************************************************\
   [Начало блока] BIQ-23781.5(intech), BIQ-29457.5(avt) Контроль за статусом и сроками представления отчетности в БР
   **************************************************************************************************************
   Изменения:
   --------------------------------------------------------------------------------------------------------------
   Дата        Автор            Jira                                    Описание
   ----------  ---------------  --------------------------------------  -----------------------------------------
   15.12.2025  Логинов Н.А.     BIQ-23781.5(intech), BIQ-29457.5(avt)   Создание
   \*************************************************************************************************************/

   -------------------------------------------------------------------------------------
   ----- Формирование UI Form для Отчёта Контрольные даты отчетности БР, Выгрузка -----
   -------------------------------------------------------------------------------------
   FUNCTION GetControlDateReportMetaUI
       RETURN CLOB
   IS
       C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
       C_REPORT_LOCALIZED_NAME VARCHAR2(64)  := 'Контрольные даты отчетности БР, Выгрузка';
       C_SYS_TAGS              VARCHAR2(256) := '["ORACLE","BR"]';
       v_meta_ui               CLOB;
   BEGIN
       WITH
           form_types(name, value) AS (
               SELECT t_label as name, t_form as value FROM dbdui_controldate_detail_dbt
           )
       SELECT
           JSON_OBJECT(
               C_META_UI_TAG__ROLES   VALUE C_ROLES FORMAT JSON,
               C_META_UI_TAG__LABEL   VALUE C_REPORT_LOCALIZED_NAME,
               C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
               C_META_UI_TAG__FORM    VALUE JSON_ARRAY(
                   -- Первая строка
                   JSON_ARRAY(
                       JSON_OBJECT(
                           'label'    VALUE 'Отчетная форма',
                           'name'     VALUE 'reportName',
                           'type'     VALUE 'select',
                           'required' VALUE 'true' FORMAT JSON,
                           'column'   VALUE 0,
                           'default'  VALUE (
                             SELECT JSON_ARRAYAGG(value RETURNING CLOB)
                             FROM form_types
                           ),
                           'multiselect' VALUE 'true' FORMAT JSON,
                           'items'       VALUE (
                             SELECT JSON_ARRAYAGG(
                                 JSON_OBJECT(
                                     'name'  VALUE name,
                                     'value' VALUE value
                                 ) RETURNING CLOB
                             )
                             FROM form_types
                           )
                           RETURNING CLOB
                       )
                   )
               ) RETURNING CLOB
           )
       INTO v_meta_ui
       FROM dual;

       RETURN v_meta_ui;
   END GetControlDateReportMetaUI;

   ------------------------------------------------------------------------
   ----- Формирование Отчёта Контрольные даты отчетности БР, Выгрузка -----
   ------------------------------------------------------------------------
   FUNCTION GetControlDate_RC_ReportRun(p_trace_id_input VARCHAR2,
                                        p_json_input CLOB,
                                        p_is_production CHAR DEFAULT '1' -- Флаг для режима прода. Не используется в данном отчёте
   )
       RETURN CLOB
   IS
       -- Константы
       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := 'control_date_tab';
       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Контрольные_даты_отчетности_БР';
       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := 'control_date_tab';
       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'GetControlDate';
       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'ControlDay_info';

       -- Входной JSON
       C_IN_REPORT_NAME_TAG    CONSTANT VARCHAR2(32)  := 'reportName';

       -- Константы - Ошибки
       C_ERR_99_CODE           CONSTANT VARCHAR2(8)   := 'ER_99';
       C_ERR_99_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: другая ошибка';

       -- Параметры входного запроса
       v_report_name_list      SYS.ODCIVARCHAR2LIST; -- Список отчётных форм

       -- Переменные
       v_json_obj              JSON_OBJECT_T;
       v_has_args              BOOLEAN := FALSE;
       v_json_output           CLOB;

       -- Валидация
       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
   BEGIN
       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Контрольные даты отчетности БР, Выгрузка', it_log.C_MSG_TYPE__DEBUG);

       -- Парсим входной JSON
       v_json_obj := JSON_OBJECT_T.parse(p_json_input);
       v_report_name_list := GetArrayFromJsonField(p_json_input, C_IN_REPORT_NAME_TAG);

       -- Если нет входных данных, отдаем мета-данные формы
       v_has_args := v_report_name_list IS NOT NULL AND v_report_name_list.COUNT > 0;
       IF NOT v_has_args THEN
         it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Наименование отчёта не указано, возвращаем Meta UI формы: Контрольные даты отчетности БР, Выгрузка', it_log.C_MSG_TYPE__DEBUG);
         RETURN BuildJsonOutput(p_body => GetControlDateReportMetaUI());
       END IF;

       -- Генерация JSON отчёта
       -- Строим напрямую через SQL JSON, а не PL/SQL JSON Object Types для экономии ресурсов
       SELECT (
           JSON_ARRAYAGG(
               JSON_OBJECT(
                   't_id'        VALUE t_id,
                   't_form'      VALUE t_form,
                   't_kind'      VALUE t_kind,
                   't_interval'  VALUE t_interval,
                   't_desc'      VALUE t_desc,
                   't_sincedate' VALUE t_sincedate
               )
               ORDER BY t_form, t_sincedate
               RETURNING CLOB
           )
       )
       INTO v_json_output
       FROM (
           SELECT
               t_id          AS t_id,       -- Уникальный идентификатор записи
               t_form        AS t_form,     -- Номер или название отчетной формы
               t_kind        AS t_kind,     -- Периодичность отчетности; 12 - ежемесячная, 4 - квартальная, 1 - ежегодная
               t_interval    AS t_interval, -- Период за который нужно подать документы
               t_desc        AS t_desc,     -- Описание отчета
               t_sincedate   AS t_sincedate -- Дата начала действия правила
           FROM dbdui_reportcontroldate_dbt
           WHERE NOT EXISTS (SELECT 1 FROM TABLE(v_report_name_list))
              OR t_form IN (SELECT COLUMN_VALUE FROM TABLE(v_report_name_list))
       );

       v_json_output := BuildSplitJsonOutput(p_trace_id_input => p_trace_id_input,
                                             p_json_input => v_json_output,
                                             p_report_date_input => NULL,
                                             p_report_tag => C_REPORT_NAME_TAG,
                                             p_items_arr_tag => C_ITEMS_ARR_TAG,
                                             p_template_name => C_TEMPLATE_NAME,
                                             p_output_file_name => C_OUTPUT_FILE_NAME,
                                             p_s3_file_name => C_S3_FILE_NAME);

       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Построение отчёта успешно завершено: Контрольные даты отчетности БР, Выгрузка', it_log.C_MSG_TYPE__DEBUG);
       RETURN v_json_output;

       EXCEPTION
           WHEN OTHERS THEN
               -- Если массив ошибок пустой, но мы всё равно сюда попали, значит произошло что-то непредвиденное
               it_error.put_error_in_stack;
               IF (v_errors_array.get_size() = 0) THEN
                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
               END IF;

               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
   END GetControlDate_RC_ReportRun;

   FUNCTION ClearTmpNewReportControlDate
       RETURN INTEGER
   IS
       PRAGMA AUTONOMOUS_TRANSACTION;
   BEGIN
       DELETE FROM dbdui_newreportcontroldate_tmp;
       COMMIT;
       RETURN 1;
   END;

   FUNCTION ParseControlDateReport(p_trace_id_input VARCHAR2, p_csv CLOB, p_errors_array IN OUT NOCOPY JSON_ARRAY_T)
       RETURN INTEGER
   IS
       PRAGMA AUTONOMOUS_TRANSACTION;
       -- Коллекция строк для пакетной вставки (по структуре таблицы dbdui_newreportcontroldate_tmp)
       TYPE t_file IS TABLE OF dbdui_newreportcontroldate_tmp%ROWTYPE;
       v_data    t_file := t_file();

       -- Константы - Ошибки
       C_ERR_01_CODE           CONSTANT VARCHAR2(8) := 'ER_01';
       C_ERR_01_MSG            CONSTANT VARCHAR2(250) := 'В файле присутствует две или более одинаковых записей: для отчета %s с начальной датой действия %s. Скорректируйте файл и попробуйте загрузить еще раз';
       C_ERR_02_CODE           CONSTANT VARCHAR2(8) := 'ER_02';
       C_ERR_02_MSG            CONSTANT VARCHAR2(350) := 'В файле присутствует некорректная запись: отчет %s с начальной датой действия %s содержит недопустимый период %s. Период должен быть указан в формате P<число>D или P<число>M (например: P12D, P2M). Скорректируйте файл и попробуйте загрузить еще раз';
       C_ERR_03_CODE           CONSTANT VARCHAR2(8) := 'ER_03';
       C_ERR_03_MSG            CONSTANT VARCHAR2(350) := 'В файле присутствует некорректная запись: Форма отчета %s не существует. Пожалуйста, обратитесь к сотрудникам Сопровождения для её создания';

       -- Переменные
       v_csv             CLOB;
       v_len             INTEGER;
       v_pos             INTEGER := 1; -- Текущая позиция в CLOB
       v_next_lb         INTEGER; -- Позиция следующего перевода строки
       v_line            VARCHAR2(32767);
       v_batch_rows_cnt  INTEGER := 0; -- Счётчик строк в батче
       v_rows_cnt        NUMBER := 0; -- Общее количество загруженных строк
       v_has_errors                 BOOLEAN := FALSE;

       -- Индексы колонок
       v_index_form      INTEGER := 1; -- Отчетная форма
       v_index_kind      INTEGER := 2; -- Периодичность подачи отчета
       v_index_interval  INTEGER := 3; -- Срок на подачу документов
       v_index_desc      INTEGER := 4; -- Описание
       v_index_sincedate INTEGER := 5; -- Начало действия
       v_err_obj         JSON_OBJECT_T;
       v_header          VC_ARR2;
       v_fields          VC_ARR2;
       c_batch_size      CONSTANT INTEGER := 50; -- Число строк, которые гарантированно влезут в VARCHAR2 (эмпирическое значение)
   BEGIN
       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Получен csv-файл для обновления справочной таблицы Контрольные даты отчетности БР (DBDUI_REPORTCONTROLDATE_DBT), парсинг запущен', it_log.C_MSG_TYPE__DEBUG);

       -- Получаем заголовки
       v_csv := REPLACE(p_csv, CHR(13) || CHR(10), CHR(10));
       v_csv := REPLACE(p_csv, '\n', CHR(10));
       v_len := DBMS_LOB.getlength(v_csv);
       v_next_lb := DBMS_LOB.instr(v_csv, CHR(10), v_pos);
       v_line  := DBMS_LOB.substr(v_csv, v_next_lb - v_pos, v_pos);
       v_pos   := v_next_lb + 1;
       v_header := string_to_table(v_line, ';');

       -- Читаем CLOB построчно, батчами по 50 строк
       WHILE v_pos <= v_len LOOP
           v_next_lb := DBMS_LOB.instr(v_csv, chr(10), v_pos);
           IF v_next_lb = 0 THEN
               v_line := DBMS_LOB.substr(v_csv, v_len - v_pos + 1, v_pos);
               v_pos  := v_len + 1; -- Парсинг завершён, выход за пределы файла для остановки на следующей итерации
           ELSE
               v_line := DBMS_LOB.substr(v_csv, v_next_lb - v_pos, v_pos);
               v_pos  := v_next_lb + 1;
           END IF;

           v_batch_rows_cnt := v_batch_rows_cnt + 1;

           -- Парсим строку
           v_fields := string_to_table(v_line, ';'); -- Разбиваем
           IF v_fields.COUNT = v_header.COUNT THEN -- Строка соответствует заголовкам
               v_data.EXTEND; -- Добавляем
               -- Заполняем
               v_data(v_data.LAST).t_form      := v_fields(v_index_form);
               v_data(v_data.LAST).t_kind      := v_fields(v_index_kind);
               v_data(v_data.LAST).t_interval  := v_fields(v_index_interval);
               v_data(v_data.LAST).t_desc      := v_fields(v_index_desc);
               v_data(v_data.LAST).t_sincedate := TO_DATE(v_fields(v_index_sincedate), 'DD.MM.YYYY');
           END IF;

           -- Если набрали батч или достигли конца файла, сливаем
           IF v_batch_rows_cnt = c_batch_size OR v_pos > v_len THEN
               DECLARE
                 EX_CODE_DUP_VAL_ON_INDEX     INTEGER := 1;
                 EX_CODE_CONSTRAINT_VIOLATION INTEGER := 2290;
                 CONSTRAINT_NAME_INTERVAL     VARCHAR2(30) := 'CHK_T_INTERVAL_TMP'; -- Имя constraint'а для проверки корректности интервала
               BEGIN
                   FORALL i IN v_data.FIRST .. v_data.LAST SAVE EXCEPTIONS
                       INSERT INTO dbdui_newreportcontroldate_tmp VALUES v_data(i);
                   -- Обработка ошибок батча
                   EXCEPTION
                       WHEN OTHERS THEN
                           v_has_errors := TRUE;
                           FOR i IN 1 .. SQL%BULK_EXCEPTIONS.COUNT LOOP
                               DECLARE
                                   v_idx  INTEGER := SQL%BULK_EXCEPTIONS(i).ERROR_INDEX;
                                   v_code NUMBER  := SQL%BULK_EXCEPTIONS(i).ERROR_CODE;
                               BEGIN
                                   IF v_code = EX_CODE_DUP_VAL_ON_INDEX THEN
                                       v_err_obj := GetErrorObjAndLog(p_trace_id_input,C_ERR_01_CODE,
                                                             UTL_LMS.FORMAT_MESSAGE(C_ERR_01_MSG, TO_CHAR(v_data(v_idx).t_form), TO_CHAR(v_data(v_idx).t_sincedate, 'DD.MM.YYYY')));
                                       p_errors_array.APPEND(v_err_obj);
                                   ELSIF v_code = EX_CODE_CONSTRAINT_VIOLATION THEN  -- Нарушение Constraint'а таблицы
                                       DECLARE
                                           v_constraint_name            VARCHAR2(250);
                                       BEGIN
                                           INSERT INTO dbdui_newreportcontroldate_tmp VALUES v_data(v_idx); -- Пытаемся вставить повторно для получения настоящего сообщения об ошибке
                                           EXCEPTION
                                               WHEN OTHERS THEN
                                                   v_constraint_name := UPPER(REGEXP_SUBSTR(SQLERRM, '\([^.]+\.(.+)\)', 1, 1, NULL, 1));
                                                   CASE v_constraint_name
                                                       WHEN CONSTRAINT_NAME_INTERVAL THEN
                                                           v_err_obj := GetErrorObjAndLog(p_trace_id_input,C_ERR_02_CODE,
                                                                                          UTL_LMS.FORMAT_MESSAGE(C_ERR_02_MSG, TO_CHAR(v_data(v_idx).t_form),
                                                                                                                 TO_CHAR(v_data(v_idx).t_sincedate, 'DD.MM.YYYY'), v_data(v_idx).t_interval));
                                                           p_errors_array.APPEND(v_err_obj);
                                                   END CASE;
                                       END;
                                   ELSE
                                       -- Логируем другие ошибки
                                       it_error.put_error_in_stack;
                                       it_log.log(p_msg => 'traceId=''' || p_trace_id_input || ''' ' || 'Непредвиденная ошибка при заполнении dbdui_newreportcontroldate_tmp: ' || SQLERRM(v_code),
                                                  p_msg_type => it_log.C_MSG_TYPE__ERROR
                                       );
                                   END IF;
                               END;
                           END LOOP;
               END;

               v_rows_cnt := v_rows_cnt + v_data.COUNT;
               v_data.DELETE;
               v_batch_rows_cnt := 0;
           END IF;
       END LOOP;

       -- Убедимся, что все вставляемые строки есть в справочной таблице наименований dbdui_controldate_detail_dbt
       FOR r IN (
           SELECT tmp.T_FORM
           FROM dbdui_newreportcontroldate_tmp tmp
           WHERE NOT EXISTS (
               SELECT 1
               FROM dbdui_controldate_detail_dbt d
               WHERE d.T_FORM = tmp.T_FORM)
       ) LOOP
           v_err_obj := GetErrorObjAndLog(p_trace_id_input,C_ERR_03_CODE,
                                          UTL_LMS.FORMAT_MESSAGE(C_ERR_03_MSG, r.T_FORM));
           p_errors_array.APPEND(v_err_obj);
       END LOOP;

       IF v_has_errors THEN
           RAISE_APPLICATION_ERROR(-20001, 'Возникли ошибки при заполнении dbdui_newreportcontroldate_tmp');
       END IF;

       it_log.log('traceId=''' || p_trace_id_input || ''' ' ||
                  'Парсинг завершен, загружено строк: ' || v_rows_cnt,
                  it_log.C_MSG_TYPE__DEBUG);

       COMMIT;
       RETURN v_rows_cnt;

       EXCEPTION
           WHEN OTHERS THEN
               it_error.put_error_in_stack;
               RAISE_APPLICATION_ERROR(-20001, 'traceId=''' || p_trace_id_input || ''' ' || 'Ошибка парсинга CSV: ' || SQLERRM);
   END ParseControlDateReport;

   -------------------------------------------------------------------------------------
   ----- Формирование UI Form для Отчёта Контрольные даты отчетности БР, Загрузка -----
   -------------------------------------------------------------------------------------
   FUNCTION UpdControlDateReportMetaUI
       RETURN CLOB
   IS
       C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
       C_REPORT_LOCALIZED_NAME VARCHAR2(64)  := 'Контрольные даты отчетности БР, Загрузка';
       C_SYS_TAGS              VARCHAR2(256) := '["ORACLE","BR"]';
       v_meta_ui               CLOB;
   BEGIN
       SELECT
           JSON_OBJECT(
               C_META_UI_TAG__ROLES   VALUE C_ROLES FORMAT JSON,
               C_META_UI_TAG__LABEL   VALUE C_REPORT_LOCALIZED_NAME,
               C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
               C_META_UI_TAG__FORM    VALUE JSON_ARRAY(
                   -- Первая строка
                   JSON_ARRAY(
                       JSON_OBJECT(
                           'label'    VALUE 'Файл c новыми сроками предоставления отчетности',
                           'name'     VALUE 'updControlDate',
                           'type'     VALUE 'file',
                           'accept'   VALUE '*.xlsx',
                           'required' VALUE 'true' FORMAT JSON,
                           'column'   VALUE 0,
                           'default'  VALUE ''
                           RETURNING CLOB
                       )
                   )
               ) RETURNING CLOB
           )
       INTO v_meta_ui
       FROM dual;

       RETURN v_meta_ui;
   END UpdControlDateReportMetaUI;

   -------------------------------------------------------------------------------------
   ----- Сливает данные о Контрольных датах отчетности БР, загруженные пользователем, в основную справочную таблицу  -----
   -------------------------------------------------------------------------------------
   FUNCTION MergeControlDate
       RETURN INTEGER
   IS
       PRAGMA AUTONOMOUS_TRANSACTION;
       v_cnt INTEGER := 0;
   BEGIN
       MERGE INTO dbdui_reportcontroldate_dbt cur
       USING dbdui_newreportcontroldate_tmp new
       ON (cur.t_form = new.t_form
           AND cur.t_sincedate = new.t_sincedate)
       WHEN MATCHED THEN
           UPDATE
           SET
             cur.t_kind     = new.t_kind,
             cur.t_interval = new.t_interval,
             cur.t_desc     = new.t_desc
           WHERE
              cur.t_kind        <> new.t_kind
              OR cur.t_interval <> new.t_interval
              OR cur.t_desc     <> new.t_desc
       WHEN NOT MATCHED THEN
           INSERT (t_form, t_kind, t_interval, t_desc, t_sincedate)
           VALUES (new.t_form, new.t_kind, new.t_interval, new.t_desc, new.t_sincedate);
       v_cnt := SQL%ROWCOUNT;
       COMMIT;
       RETURN v_cnt;
   END;

   -------------------------------------------------------------------------------------
   ----- Формирование UI Form для Отчёта Контрольные даты отчетности БР, Загрузка -----
   -------------------------------------------------------------------------------------
   FUNCTION UpdControlDate_RC_ReportRun(p_trace_id_input VARCHAR2,
                                        p_json_input CLOB,
                                        p_is_production CHAR DEFAULT '1' -- Флаг для режима прода. Не используется в данном отчёте
   )
       RETURN CLOB
   IS
       -- Константы
       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := 'control_date_tab';
       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Новые_контрольные_даты_отчетности_БР';
       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := 'control_date_tab';
       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'GetControlDate';
       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'ControlDay_info';

       -- Входной JSON
       C_IN_CSV_FILE_JPATH     CONSTANT VARCHAR2(32)  := '$.updControlDate[0]'; -- Файл будет только один, но фронт присылает массив из одного файла

       -- Константы - Ошибки
       C_ERR_99_CODE           CONSTANT VARCHAR2(8)   := 'ER_99';
       C_ERR_99_MSG            CONSTANT VARCHAR2(64)  := 'СОФР не смог сформировать отчет: другая ошибка';

       -- Параметры входного запроса
       v_new_ctrldate_csv      CLOB;

       -- Переменные
       v_has_args              BOOLEAN := FALSE;
       v_sql                   VARCHAR2(2048);
       v_is_clear              INTEGER;
       v_inserted_rows         INTEGER;
       v_updated_rows          INTEGER;
       v_json_output           CLOB;

       -- Валидация
       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
   BEGIN
       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Контрольные даты отчетности БР, Загрузка', it_log.C_MSG_TYPE__DEBUG);

       -- Парсим входной JSON
       v_sql := '
          SELECT JSON_VALUE(:j, ''' || C_IN_CSV_FILE_JPATH || ''' RETURNING CLOB)
          FROM dual';
       EXECUTE IMMEDIATE v_sql INTO v_new_ctrldate_csv USING p_json_input;

       -- Если нет входных данных, отдаем мета-данные формы
       v_has_args := v_new_ctrldate_csv IS NOT NULL;
       IF NOT v_has_args THEN
           it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Отсутствует файл для обновления контрольных дат, возвращаем Meta UI формы: Контрольные даты отчетности БР, Загрузка', it_log.C_MSG_TYPE__DEBUG);
           RETURN BuildJsonOutput(p_body => UpdControlDateReportMetaUI());
       END IF;

       -- Парсим Контрольные даты отчетности БР
       SELECT ClearTmpNewReportControlDate INTO v_is_clear FROM dual; -- Очистим временную таблицу, на случай, если там что-то есть
       v_inserted_rows := ParseControlDateReport(p_trace_id_input, v_new_ctrldate_csv, v_errors_array);

       SELECT MergeControlDate() INTO v_updated_rows FROM dual;

       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Слияние Контрольных дат отчетности БР завершено, добавлено/обновлено строк: ' || v_updated_rows, it_log.C_MSG_TYPE__DEBUG);

       -- Генерация JSON отчёта
       -- Строим напрямую через SQL JSON, а не PL/SQL JSON Object Types для экономии ресурсов
       SELECT (
           JSON_ARRAYAGG(
               JSON_OBJECT(
                   't_id'        VALUE t_id,
                   't_form'      VALUE t_form,
                   't_kind'      VALUE t_kind,
                   't_interval'  VALUE t_interval,
                   't_desc'      VALUE t_desc,
                   't_sincedate' VALUE t_sincedate
               )
               ORDER BY t_form, t_sincedate
               RETURNING CLOB
           )
       )
       INTO v_json_output
       FROM (
           SELECT
               t_id          AS t_id,       -- Уникальный идентификатор записи
               t_form        AS t_form,     -- Номер или название отчетной формы
               t_kind        AS t_kind,     -- Периодичность отчетности; 12 - ежемесячная, 4 - квартальная, 1 - ежегодная
               t_interval    AS t_interval, -- Период за который нужно подать документы
               t_desc        AS t_desc,     -- Описание отчета
               t_sincedate   AS t_sincedate -- Дата начала действия правила
           FROM DBDUI_REPORTCONTROLDATE_DBT
       );

       v_json_output := BuildSplitJsonOutput(p_trace_id_input => p_trace_id_input,
                                             p_json_input => v_json_output,
                                             p_report_date_input => NULL,
                                             p_report_tag => C_REPORT_NAME_TAG,
                                             p_items_arr_tag => C_ITEMS_ARR_TAG,
                                             p_template_name => C_TEMPLATE_NAME,
                                             p_output_file_name => C_OUTPUT_FILE_NAME,
                                             p_s3_file_name => C_S3_FILE_NAME);

       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Построение отчёта успешно завершено: Контрольные даты отчетности БР, Загрузка', it_log.C_MSG_TYPE__DEBUG);
       RETURN v_json_output;

       EXCEPTION
           WHEN OTHERS THEN
               -- Если массив ошибок пустой, но мы всё равно сюда попали, значит произошло что-то непредвиденное
               it_error.put_error_in_stack;
               IF (v_errors_array.get_size() = 0) THEN
                 v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                         C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
               END IF;

               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
   END UpdControlDate_RC_ReportRun;

  -------------------------------------------------------------------------------------
  ----- Формирование UI Form для отчёта Расшифровка отчетной формы 04090711 БР -----
  -------------------------------------------------------------------------------------
--   FUNCTION Decrypt711ReportMetaUI
--       RETURN CLOB
--   IS
--       C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
--       C_REPORT_LOCALIZED_NAME VARCHAR2(128) := 'Расшифровка отчетной формы 04090711';
--       C_SYS_TAGS              VARCHAR2(256) := '["ORACLE","Decrypt"]';
--       v_meta_ui               CLOB;
--       v_history_start_year    INTEGER := 2019;
--   BEGIN
--       WITH
--           years (value) AS (
--               SELECT v_history_start_year + LEVEL - 1 AS year
--               FROM dual
--               CONNECT BY v_history_start_year + LEVEL - 1 <= EXTRACT(YEAR FROM SYSDATE)
--           ),
--           months (name, value) AS (
--               SELECT
--                   TO_CHAR(
--                           ADD_MONTHS(DATE '0001-01-01', LEVEL - 1),
--                           'FMMonth',
--                           'NLS_DATE_LANGUAGE=RUSSIAN'
--                   ) AS name,
--                   LEVEL AS value
--               FROM dual
--               CONNECT BY LEVEL <= 12
--           ),
--           prev_period AS (
--               SELECT
--                   TO_NUMBER(TO_CHAR(ADD_MONTHS(SYSDATE, -1), 'YYYY')) AS year,
--                   TO_NUMBER(TO_CHAR(ADD_MONTHS(SYSDATE, -1), 'FMMM')) AS month
--               FROM dual
--       )
--       SELECT
--           JSON_OBJECT(
--               C_META_UI_TAG__ROLES   VALUE C_ROLES FORMAT JSON,
--               C_META_UI_TAG__LABEL   VALUE C_REPORT_LOCALIZED_NAME,
--               C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
--               C_META_UI_TAG__FORM    VALUE JSON_ARRAY(
--                   -- Первая строка
--                   JSON_ARRAY(
--                       JSON_OBJECT(
--                           'label'    VALUE 'Период',
--                           'name'     VALUE 'period',
--                           'type'     VALUE 'select',
--                           'required' VALUE 'true' FORMAT JSON,
--                           'column'   VALUE 0,
--                           'default'  VALUE prev_period.month,
--                           'multiselect' VALUE 'false' FORMAT JSON,
--                           'items'       VALUE (
--                               SELECT JSON_ARRAYAGG(
--                                   JSON_OBJECT(
--                                           'name'  VALUE name,
--                                           'value' VALUE value
--                                   ) RETURNING CLOB
--                               )
--                               FROM months
--                           )
--                           RETURNING CLOB
--                       ),
--                       JSON_OBJECT(
--                           'label'    VALUE 'Год',
--                           'name'     VALUE 'year',
--                           'type'     VALUE 'select',
--                           'required' VALUE 'true' FORMAT JSON,
--                           'column'   VALUE 1,
--                           'default'  VALUE prev_period.year,
--                           'multiselect' VALUE 'false' FORMAT JSON,
--                           'items'       VALUE (
--                               SELECT JSON_ARRAYAGG(
--                                   JSON_OBJECT(
--                                       'name'  VALUE value,
--                                       'value' VALUE value
--                                   )
--                                   ORDER BY value DESC
--                                   RETURNING CLOB
--                               )
--                               FROM years
--                           ) RETURNING CLOB
--                       )
--                   )
--               ) RETURNING CLOB
--           )
--       INTO v_meta_ui
--       FROM prev_period;
--
--       RETURN v_meta_ui;
--   END Decrypt711ReportMetaUI;
--
--   -------------------------------------------------------------------------------------
--   ----- Подготавливает данные для Расшифровки отчетной формы 04090711, Раздел 3 -----
--   ----- Запросы сформированы на базе основного отчёта из dl711Part3.mac -----
--   -------------------------------------------------------------------------------------
--   FUNCTION Form711p3PrepareData(p_trace_id_input VARCHAR2,
--                                 p_rd_from DATE,
--                                 p_rd_to DATE
--   )
--       RETURN INTEGER
--   IS
--       PRAGMA AUTONOMOUS_TRANSACTION;
--
--       -- Переменные
--       v_inserted_rows         INTEGER;
--   BEGIN
--       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущен сбор данных по Форме 0409711, Раздел 3', it_log.C_MSG_TYPE__DEBUG);
--
--       -- Очистим временную таблицу
--       DELETE FROM d711Part3_tmp;
--
--       -- Кроме граф 211-214
--       INSERT INTO
--           d711Part3_tmp (
--               T_ISSUERINN,
--               T_ISSUEROGRN,
--               T_ISSUERCOUNTRYCODE,
--               T_LSIN,
--               T_ISIN,
--               T_SALEREPOAMOUNT,
--               T_TRANSLOANAMOUNT,
--               T_BUYREPOAMOUNT,
--               T_ACCEPTLOANAMOUNT,
--               T_TRANSPLEDGEBOAMOUNT,
--               T_TRANSPLEDGEAMOUNT,
--               T_ACCEPTPLEDGEAMOUNT,
--               T_NUMBER) (
--           SELECT
--               q.T_ISSUERINN,
--               q.T_ISSUEROGRN,
--               q.T_ISSUERCOUNTRYCODE,
--               q.T_LSIN,
--               q.T_ISIN,
--               q.T_SALEREPOAMOUNT,
--               q.T_TRANSLOANAMOUNT,
--               q.T_BUYREPOAMOUNT,
--               q.T_ACCEPTLOANAMOUNT,
--               q.T_TRANSPLEDGEBOAMOUNT,
--               q.T_TRANSPLEDGEAMOUNT,
--               q.T_ACCEPTPLEDGEAMOUNT,
--               q.T_NUMBER
--           FROM (
--               SELECT
--                   rsi_rsbparty.GetPartyCode(issuer.t_Issuer, 16) AS T_ISSUERINN, -- магическое число из параметров приложения
--                   rsi_rsbparty.GetPartyCode(issuer.t_Issuer, 27) AS T_ISSUEROGRN, -- магическое число из параметров приложения
--                   CHR(1) AS T_ISSUERCOUNTRYCODE,
--                   avr.T_LSIN AS T_LSIN,
--                   avr.T_ISIN AS T_ISIN,
--                   (CASE
--                        WHEN Rsb_Secur.IsSale (Opr.oGrp) = 1
--                            THEN rq_sp1.t_Amount - (
--                                SELECT NVL(SUM(CompRQ.t_Amount * (CASE WHEN CompRQ.t_Kind = rq_sp1.t_Kind THEN - 1 ELSE 1 END)), 0)
--                                FROM DDLRQ_DBT CompRQ
--                                WHERE CompRQ.t_Type = 9
--                                    AND CompRQ.t_FIID = rq_sp1.t_FIID
--                                    AND CompRQ.t_DocKind = rq_sp1.t_DocKind
--                                    AND CompRQ.t_DocID = rq_sp1.t_DocID
--                                    AND rsi_dlrq.RSI_GetRQStateOnDate (CompRQ.t_ID, p_rd_to) = 2 )
--                        ELSE 0
--                   END) AS T_SALEREPOAMOUNT,
--                   0 AS T_TRANSLOANAMOUNT,
--                   (CASE
--                        WHEN Rsb_Secur.IsBuy (Opr.oGrp) = 1 THEN rq_sp1.t_Amount - (
--                            SELECT NVL(SUM(CompRQ.t_Amount * (CASE WHEN CompRQ.t_Kind = rq_sp1.t_Kind THEN - 1 ELSE 1 END)), 0)
--                            FROM DDLRQ_DBT CompRQ
--                            WHERE CompRQ.t_Type = 9
--                                AND CompRQ.t_FIID = rq_sp1.t_FIID
--                                AND CompRQ.t_DocKind = rq_sp1.t_DocKind
--                                AND CompRQ.t_DocID = rq_sp1.t_DocID
--                                AND rsi_dlrq.RSI_GetRQStateOnDate (CompRQ.t_ID, p_rd_to) = 2 )
--                        ELSE 0
--                   END) AS T_BUYREPOAMOUNT,
--                   0 AS T_ACCEPTLOANAMOUNT,
--                   0 AS T_TRANSPLEDGEBOAMOUNT,
--                   0 AS T_TRANSPLEDGEAMOUNT,
--                   0 AS T_ACCEPTPLEDGEAMOUNT,
--                   tick.t_DealCode AS T_NUMBER
--               FROM
--                   davoiriss_dbt avr,
--                   dfininstr_dbt fin,
--                   ddlrq_dbt rq_sp1,
--                   ddlrq_dbt rq_sp2,
--                   ddl_tick_dbt Tick,
--                   davrkinds_dbt avrKinds,
--                   (
--                       SELECT t_Kind_Operation, rsb_secur.get_OperationGroup (t_SysTypes) oGrp
--                       FROM doprkoper_dbt) Opr,
--                   (
--                       SELECT
--                           CASE
--                               WHEN RSI_RSB_FIInstr.fi_avrkindsgetroot (2, fin2.t_AvoirKind) = 10 THEN (
--                                   SELECT finParent.t_Issuer
--                                   FROM dfininstr_dbt finParent
--                                   WHERE finParent.t_FIID = fin2.t_ParentFI)
--                               ELSE fin2.t_Issuer
--                               END AS t_Issuer,
--                           fin2.t_FIID
--                       FROM dfininstr_dbt fin2) issuer
--               WHERE
--                   rq_sp1.t_Type = 8
--                   AND rq_sp1.t_DealPart = 1
--                   AND rq_sp1.t_FIID = avr.t_FIID
--                   AND Tick.t_ClientID = -1
--                   AND Tick.t_DealID = rq_sp1.t_DocID
--                   AND Tick.t_BOfficeKind = rq_sp1.t_DocKind
--                   AND Tick.t_DealStatus > 0
--                   -- 	AND Tick.t_department IN (1) -- как будто бы, нам эта фильтрация не нужна, так что берём все department
--                   AND rq_sp2.t_Type = 8
--                   AND rq_sp2.t_DealPart = 2
--                   AND rq_sp2.t_FIID = rq_sp1.t_FIID
--                   AND rq_sp2.t_DocID = Tick.t_DealID
--                   AND rq_sp2.t_DocKind = Tick.t_BOfficeKind
--                   AND Opr.t_Kind_Operation = Tick.t_DealType
--                   AND Rsb_Secur.IsRepo (Opr.oGrp) = 1
--                   AND rsi_dlrq.RSI_GetRQStateOnDate (rq_sp1.t_ID, p_rd_to) = 2
--                   AND rsi_dlrq.RSI_GetRQStateOnDate (rq_sp2.t_ID, p_rd_to) NOT IN(2, 7)
--                   AND fin.t_FIID = avr.t_FIID
--                   AND issuer.t_FIID = avr.t_fiid
--                   AND avrKinds.t_FI_Kind = 2
--                   AND avrKinds.t_AvoirKind = fin.t_AvoirKind) q );
--
--       -- Графы 211-214 по лотам ПВО
--       INSERT INTO
--           d711Part3_tmp (T_ISSUERINN,
--                          T_ISSUEROGRN,
--                          T_ISSUERCOUNTRYCODE,
--                          T_LSIN,
--                          T_ISIN,
--                          T_SALEREPOAMOUNT,
--                          T_TRANSLOANAMOUNT,
--                          T_BUYREPOAMOUNT,
--                          T_ACCEPTLOANAMOUNT,
--                          T_TRANSPLEDGEBOAMOUNT,
--                          T_TRANSPLEDGEAMOUNT,
--                          T_ACCEPTPLEDGEAMOUNT,
--                          T_NUMBER)(
--           SELECT
--               q.T_ISSUERINN,
--               q.T_ISSUEROGRN,
--               q.T_ISSUERCOUNTRYCODE,
--               q.T_LSIN,
--               q.T_ISIN,
--               q.T_SALEREPOAMOUNT,
--               q.T_TRANSLOANAMOUNT,
--               q.T_BUYREPOAMOUNT,
--               q.T_ACCEPTLOANAMOUNT,
--               q.T_TRANSPLEDGEBOAMOUNT,
--               q.T_TRANSPLEDGEAMOUNT,
--               q.T_ACCEPTPLEDGEAMOUNT,
--               q.T_NUMBER
--           FROM
--               (
--                   SELECT
--                       rsi_rsbparty.GetPartyCode(issuer.t_Issuer, 16) AS T_ISSUERINN, -- магическое число из параметров приложения
--                       rsi_rsbparty.GetPartyCode(issuer.t_Issuer, 27) AS T_ISSUEROGRN, -- магическое число из параметров приложения
--                       CHR(1) AS T_ISSUERCOUNTRYCODE,
--                       avr.T_LSIN AS T_LSIN,
--                       avr.T_ISIN AS T_ISIN,
--                       0 AS T_SALEREPOAMOUNT,
--                       0 AS T_TRANSLOANAMOUNT,
--                       0 AS T_BUYREPOAMOUNT,
--                       0 AS T_ACCEPTLOANAMOUNT,
--                       0 AS T_TRANSPLEDGEBOAMOUNT,
--                       0 AS T_TRANSPLEDGEAMOUNT,
--                       0 AS T_ACCEPTPLEDGEAMOUNT,
--                       tick.t_DealCode AS T_NUMBER
--                   FROM
--                       davoiriss_dbt avr,
--                       dfininstr_dbt fin,
--                       v_scwrthistex v,
--                       ddlrq_dbt rq,
--                       ddl_tick_dbt Tick,
--                       davrkinds_dbt avrKinds,
--                       (
--                           SELECT t_Kind_Operation, rsb_secur.get_OperationGroup (t_SysTypes) oGrp
--                           FROM doprkoper_dbt) Opr,
--                       (
--                           SELECT
--                               CASE
--                                   WHEN RSI_RSB_FIInstr.fi_avrkindsgetroot (2, fin2.t_AvoirKind) = 10 THEN (
--                                       SELECT finParent.t_Issuer
--                                       FROM dfininstr_dbt finParent
--                                       WHERE finParent.t_FIID = fin2.t_ParentFI)
--                                   ELSE fin2.t_Issuer
--                                   END AS t_Issuer,
--                               fin2.t_FIID
--                           FROM
--                               dfininstr_dbt fin2) issuer
--                   WHERE
--                       v.t_Buy_Sale <> 1
--                     AND v.t_State = 1
--                     AND v.t_Portfolio IN (6, 12)
--                     AND v.t_FIID = rq.t_FIID
--                     AND v.t_ChangeDate <= p_rd_to
--                     AND v.t_Amount <> 0
--                     AND v.t_Instance = (
--                       SELECT MAX(v2.t_Instance)
--                       FROM v_scwrthistex v2
--                       WHERE v2.t_SumID = v.t_SumID
--                         AND v2.t_ChangeDate <= p_rd_to )
--                     AND avr.t_FIID = v.t_FIID
--                     AND rq.t_ID = v.t_DocID
--                     AND Tick.t_ClientID = -1
--                     AND Tick.t_DealID = v.t_DealID
--                     AND Tick.t_DealStatus > 0
-- -- 			AND Tick.t_department IN (1) -- как будто бы, нам эта фильтрация не нужна, так что берём все department
--                     AND Opr.t_Kind_Operation = Tick.t_DealType
--                     AND Rsb_Secur.IsRepo (Opr.oGrp) = 1
--                     AND fin.t_FIID = avr.t_FIID
--                     AND issuer.t_FIID = avr.t_fiid
--                     AND avrKinds.t_FI_Kind = 2
--                     AND avrKinds.t_AvoirKind = fin.t_AvoirKind) q );
--
--       -- Графа 229 Переданные в ДУ - не нужны. У них только поля связанные с ДУ.
--       -- Учтенные векселя - не нужны. У них только поля связанные с ДУ. (Если понадобятся: ISIN у векселей нет, поэтому, в теории, можно склеить по code711(Тип ценной бумаги (вид финансового инструмента)) + ИНН эмитента + ОГРН)
--
--       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Данные собраны для расшифровки по Форме 0409711, Раздел 3', it_log.C_MSG_TYPE__DEBUG);
--
--       SELECT COUNT(*)
--       INTO v_inserted_rows
--       FROM d711Part3_tmp;
--
--       COMMIT;
--       RETURN v_inserted_rows;
--
--       EXCEPTION
--           WHEN OTHERS THEN
--               it_error.put_error_in_stack;
--               RAISE_APPLICATION_ERROR(-20001, 'Непредвиденная ошибка при сборе данных по Форме 0409711, Раздел 3: ' || SQLERRM);
--
--   END Form711p3PrepareData;
--
--   -----------------------------------------------------------------------
--   ----- Формирование отчёта Расшифровка отчёта БР по форме №0409711 -----
--   -----------------------------------------------------------------------
--   FUNCTION Decrypt711Part3(p_trace_id_input VARCHAR2,
--                            p_date_from DATE,
--                            p_date_to DATE)
--       RETURN CLOB
--   IS
--       -- Константы
--       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := '0409711_ch3_decryption';
--       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Расшифровка_0409711_раздел_3';
--       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := '0409711_ch3_decryption';
--       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'chapter_3';
--       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'dataset';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8)  := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(64) := 'СОФР не смог сформировать отчет: другая ошибка';
--
--       -- Переменные
--       v_inserted_rows         INTEGER;
--       v_json_output           CLOB;
--
--       -- Валидация
--       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
--   BEGIN
--       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение части отчёта: Расшифровка отчёта БР по форме №0409711, Раздел 3', it_log.C_MSG_TYPE__DEBUG);
--
--       -- Сбор данных для расшифровки отчёта
--       v_inserted_rows := Form711p3PrepareData(p_trace_id_input, p_date_from, p_date_to);
--
--       -- Генерация JSON отчёта
--       WITH
--           -- Данные из ruData для сравнения
--           ruData AS (
--               -- IMPROVE как будет известно, какой конкретно набор полей требует сравнения, можно оптимизировать запрос
--               SELECT
--                   COALESCE(emInf.shortname_rus_nrd, emInf.shortname_rus) AS RUD_IssuerName,
--                   emInf.inn AS RUD_IssuerINN,
--                   emInf.ogrn AS RUD_IssuerOGRN,
--                   emInf.country_oksm AS RUD_IssuerCountryCode,
--                   emFinInf.sec_type_br_code AS RUD_Code711,
--                   emFinInf.regcode AS RUD_LSIN,
--                   emFinInf.isincode AS RUD_ISIN,
--                   emFinInf.cfi AS RUD_CFICode,
--                   fin.t_iso_number AS RUD_FaceValueFICode,
--                   emFinInf.facevalue AS RUD_FaceValue
--               FROM sofr_info_emitents emInf -- Информация об эмитенте из RuData
--                        LEFT JOIN sofr_info_fintoolreferencedata emFinInf -- Информация о бумагах эмитента из RuData
--                                  ON emInf.inn = emFinInf.issuerinn
--                                      AND emInf.Okpo = emFinInf.issuerokpo
--                        LEFT JOIN dfininstr_dbt fin -- Подтягивание кода валюты по названию валюты бумаги эмитента из RuData
--                                  ON fin.t_ccy = emFinInf.faceftname
--           ),
--           -- Ищем id готового отчёта
--           report_meta AS (
--               SELECT cy_rdate.t_reportid reportId
--               FROM dcy_rdate_dbt cy_rdate
--               WHERE cy_rdate.t_iformid = 19
--                 AND cy_rdate.t_bdprevdate = p_date_from
--                 AND cy_rdate.t_bdrepdate = p_date_to),
--           -- Ищем форму для соответствующего раздела
--           form AS (SELECT t_attributeid attid
--                    FROM dcy_varsd_dbt
--                    WHERE t_szvarname LIKE 'Ф711_Раздел3'
--                      AND t_iformid = (SELECT t_iformid FROM dcy_forms_dbt dfd WHERE dfd.t_szformname = 'Форма 711')),
--           -- Вытягиваем неформатированные данные, сбор данных разного типа по всем таблицам
--           rawdata AS (
--               SELECT
--                   (SELECT t_szvarname
--                    FROM dcy_varsd_dbt
--                    WHERE t_attributeid = rcbvalue.t_attributeid) AS t_attributename,
--                   (SELECT t_szfldname
--                    FROM dcy_strud_dbt
--                    WHERE t_fieldid = rcbvalue.t_fieldid)          AS t_fieldname,
--                   NVL(rcbvalue.t_valueid, 0)                      AS valueid,
--                   rcbvalue.t_exact                                AS exact,
--                   rcbvalue.t_scaled                               AS scaled,
--                   rcbvalue.t_date                                 AS dt,
--                   rcbvalue.t_string                               AS string
-- --                  , rcbvalue.* -- todo как будто бы можно удалить
--               FROM (
--                   -- Действительные значения
--                   SELECT t_reportid    AS t_reportid,
--                          t_attributeid AS t_attributeid,
--                          t_valueid     AS t_valueid,
--                          t_fieldid     AS t_fieldid,
--                          t_exact       AS t_exact,
--                          t_scaled      AS t_scaled,
--                          NULL          AS t_date,
--                          NULL          AS t_string
--                   FROM drcbrealv_dbt
--                   UNION ALL
--                   -- Даты
--                   SELECT t_reportid    AS t_reportid,
--                          t_attributeid AS t_attributeid,
--                          t_valueid     AS t_valueid,
--                          t_fieldid     AS t_fieldid,
--                          NULL          AS t_exact,
--                          NULL          AS t_scaled,
--                          t_date        AS t_date,
--                          NULL          AS t_string
--                   FROM drcbdatev_dbt
--                   UNION ALL
--                   -- Строковые значения
--                   SELECT t_reportid    AS t_reportid,
--                          t_attributeid AS t_attributeid,
--                          t_valueid     AS t_valueid,
--                          t_fieldid     AS t_fieldid,
--                          NULL          AS t_exact,
--                          NULL          AS t_scaled,
--                          NULL          AS t_date,
--                          t_string AS t_string
--                   FROM drcbstrv_dbt
--               ) rcbvalue
--               WHERE rcbvalue.t_reportid = (SELECT reportId FROM report_meta)
--                 AND t_attributeid = (SELECT attid FROM form)),
--           -- Всё ещё неформатированные данные, но в формате ключ-значение + номер строки
--           src AS (SELECT valueid,
--                          t_fieldname,
--                          COALESCE(
--                                  TO_CHAR(rd.exact),
--                                  TO_CHAR(rd.scaled),
--                                  TO_CHAR(rd.dt, 'YYYY-MM-DD HH24:MI:SS'),
--                                  rd.string
--                          ) AS val
--                   FROM rawdata rd),
--           -- Разворачиваем данные в нормальную таблицу + донасыщаем данными из ruData для дальнейшей сверки
--           base_report AS (
--               SELECT
--                   TO_CHAR(ROW_NUMBER() OVER (ORDER BY orderNum)) AS counter,
--                   base.*,
--                   rud.*
--               FROM (
--                   SELECT
--                       MAX(CASE WHEN t_fieldname = 'counter' THEN val END) * 10000           AS orderNum,
--                       TO_CHAR(MAX(CASE WHEN t_fieldname = 'counter' THEN val END))          AS base_counter,
--                       ''                                                                    AS Account,
--                       MAX(CASE WHEN t_fieldname = 'IssuerName' THEN val END)                AS IssuerName,
--                       MAX(CASE WHEN t_fieldname = 'IssuerINN' THEN val END)                 AS IssuerINN,
--                       MAX(CASE WHEN t_fieldname = 'IssuerOGRN' THEN val END)                AS IssuerOGRN,
--                       MAX(CASE WHEN t_fieldname = 'IssuerCountryCode' THEN val END)         AS IssuerCountryCode,
--                       MAX(CASE WHEN t_fieldname = 'Code711' THEN val END)                   AS Code711,
--                       MAX(CASE WHEN t_fieldname = 'LSIN' THEN val END)                      AS LSIN,
--                       MAX(CASE WHEN t_fieldname = 'ISIN' THEN val END)                      AS ISIN,
--                       MAX(CASE WHEN t_fieldname = 'КодCFI' THEN val END)                    AS CFICode,
--                       MAX(CASE WHEN t_fieldname = 'FaceValueFICode' THEN val END)           AS FaceValueFICode,
--                       MAX(CASE WHEN t_fieldname = 'FaceValue' THEN val END)                 AS FaceValue,
--                       MAX(CASE WHEN t_fieldname = 'FaceValuePoint' THEN val END)            AS FaceValuePoint,
--                       ToLocalNumber(MAX(CASE WHEN t_fieldname = 'SaleREPOAmount' THEN val END))      AS SaleREPOAmount,
--                       ToLocalNumber(MAX(CASE WHEN t_fieldname = 'TransLoanAmount' THEN val END))     AS TransLoanAmount,
--                       ToLocalNumber(MAX(CASE WHEN t_fieldname = 'BuyREPOAmount' THEN val END))       AS BuyREPOAmount,
--                       ToLocalNumber(MAX(CASE WHEN t_fieldname = 'AcceptLoanAmount' THEN val END))    AS AcceptLoanAmount,
--                       ToLocalNumber(MAX(CASE WHEN t_fieldname = 'TransPledgeBOAmount' THEN val END)) AS TransPledgeBOAmount,
--                       ToLocalNumber(MAX(CASE WHEN t_fieldname = 'TransPledgeAmount' THEN val END))   AS TransPledgeAmount,
--                       ToLocalNumber(MAX(CASE WHEN t_fieldname = 'AcceptPledgeAmount' THEN val END))  AS AcceptPledgeAmount,
--                       MAX(CASE WHEN t_fieldname = 'note' THEN val END)                      AS note
--                   FROM src
--                   GROUP BY valueid
--                   ORDER BY valueid) base
--               LEFT JOIN ruData rud
--                   ON rud.RUD_IssuerINN = IssuerINN
--                       AND rud.RUD_LSIN = LSIN
--                       AND rud.RUD_ISIN = ISIN
--               WHERE base.IssuerName IS NOT NULL AND base.IssuerName <> CHR(1)
--           ),
--           -- Собираем данные для расшифровки
--           details AS (
--               SELECT
--                   --DISTINCT
--                   ACC.t_account                AS T_ACCOUNT,
--                   t.T_ISSUERINN                AS IssuerINN,
--                   t.T_ISSUEROGRN               AS IssuerOGRN,
--                   t.T_CODE711                  AS Code711,
--                   t.T_LSIN                     AS LSIN,
--                   t.T_ISIN                     AS ISIN,
--                   SUM(t.T_SALEREPOAMOUNT)      AS SaleREPOAmount,
--                   SUM(t.T_TransLoanAmount)     AS TransLoanAmount,
--                   SUM(t.T_BuyREPOAmount)       AS BuyREPOAmount,
--                   SUM(t.T_AcceptLoanAmount)    AS AcceptLoanAmount,
--                   SUM(t.T_TransPledgeBOAmount) AS TransPledgeBOAmount,
--                   SUM(t.T_TransPledgeAmount)   AS TransPledgeAmount,
--                   SUM(t.T_AcceptPledgeAmount)  AS AcceptPledgeAmount,
--                   SUM(t.T_TransDUAmount)       AS TransDUAmount,
--                   SUM(t.T_TransRightsDUAmount) AS TransRightsDUAmount
--               FROM
--                   d711Part3_tmp t
--                       LEFT JOIN ddl_tick_dbt tick ON t.T_NUMBER = tick.T_DEALCODE
--                       LEFT JOIN ddl_leg_dbt leg ON leg.t_legkind = 0 -- хардкод
--                       AND tick.t_dealid = leg.T_DEALID
--                       AND leg.t_legid = 0 -- хардкод
--                       LEFT JOIN dmcaccdoc_dbt ACC ON ACC.t_dockind = 176 -- магическое число
--                       AND ACC.t_docid = leg.t_id
--                       AND ACC.t_catid = 361 -- магическое число
--                       AND ACC.T_FIROLE = 4 -- полу-магическое число FIROLEE == 4 - контрактив
--               GROUP BY
--                   ACC.t_account,
--                   t.T_ISSUERINN,
--                   t.T_ISSUEROGRN,
--                   t.T_CODE711,
--                   t.T_LSIN,
--                   t.T_ISIN),
--           -- Добавляем нумерацию по группам
--           details_num AS (
--               SELECT
--                   d.*,
--                   ROW_NUMBER() OVER (
--                       PARTITION BY d.IssuerINN, d.IssuerOGRN, d.ISIN
--                       ORDER BY d.t_account
--                   ) AS sub_num
--               FROM details d
--           ),
--           -- Формируем строки расшифровки + донасыщаем недостающие данные из базового отчёта
--           details_report AS (
--               SELECT
--                   base.ordernum + d.sub_num AS orderNum,
--                   CASE
--                       WHEN d.sub_num IS NULL THEN TO_CHAR(base.counter)
--                       ELSE TO_CHAR(base.counter) || '.' || TO_CHAR(d.sub_num)
--                   END AS counter,
--                   d.T_ACCOUNT AS Account,
--                   base.IssuerName,
--                   base.IssuerINN,
--                   base.IssuerOGRN,
--                   base.IssuerCountryCode,
--                   base.Code711,
--                   base.LSIN,
--                   base.ISIN,
--                   base.CFICode,
--                   base.FaceValueFICode,
--                   base.FaceValue,
--                   base.FaceValuePoint,
--                   base.RUD_FaceValue AS FaceValueRuData,
--                   COALESCE(d.SaleREPOAmount, 0) AS SaleREPOAmount, -- Ц/б, переданные по сделкам прямого репо
--                   COALESCE(d.TransLoanAmount, 0) AS TransLoanAmount, -- Ц/б, переданные по сделкам займа
--                   COALESCE(d.BuyREPOAmount, 0) AS BuyREPOAmount, -- Ц/б, полученные по сделкам обратного репо
--                   COALESCE(d.AcceptLoanAmount, 0) AS AcceptLoanAmount, -- Ц/б, полученные по сделкам займа
--                   COALESCE(d.TransPledgeBOAmount, 0) AS TransPledgeBOAmount,  -- Ц/б, переданные в залог по обязательствам кредитной организации
--                   COALESCE(d.TransPledgeAmount, 0) AS TransPledgeAmount, -- Ц/б, переданные в залог по обязательствам третьих лиц
--                   COALESCE(d.AcceptPledgeAmount, 0) AS AcceptPledgeAmount, -- Ц/б, принятые в залог
--                   '' as note
--               FROM base_report base
--                   LEFT JOIN details_num d
--                       ON d.ISIN = base.ISIN
--               WHERE d.sub_num IS NOT NULL
--               ORDER BY base.counter, d.sub_num)
--       -- Строим напрямую через SQL JSON, а не PL/SQL JSON Object Types для экономии ресурсов
--       SELECT (
--                  JSON_ARRAYAGG(
--                          JSON_OBJECT(
--                                  'orderNum'               VALUE orderNum,              -- Сервисное поле для сортировки
--                                  'counter'                VALUE counter,               -- Порядковый номер (только для UI вывода)
--                                  'secBalanceNum'          VALUE Account,               -- Номер лицевого счёта
--                                  'emiName'                VALUE IssuerName,            -- Наименование эмитента
--                                  'emiINN'                 VALUE IssuerINN,             -- ИНН эмитента
--                                  'emiOGRN'                VALUE IssuerOGRN,            -- ОГРН эмитента
--                                  'emiCountry'             VALUE IssuerCountryCode,     -- Код страны эмитента по ОКСМ
--                                  'secType'                VALUE Code711,               -- Тип ценной бумаги (вид финансового инструмента)
--                                  'regNum'                 VALUE LSIN,                  -- Регистрационный номер выпуска
--                                  'secISIN'                VALUE ISIN,                  -- Код ISIN ценной бумаги
--                                  'CFIcode'                VALUE CFICode,               -- Код CFI
--                                  'curCode'                VALUE FaceValueFICode,       -- Код валюты ценной бумаги
--                                  'secNomPrice'            VALUE FaceValue,             -- Номинальная стоимость ценной бумаги
--                                  'secNomPricePoint'       VALUE FaceValuePoint,        -- Знаковая точность Номинальной стоимости ценной бумаги
--                                  'secNomPriceRuData'      VALUE FaceValueRuData,       -- Номинальная стоимость ценной бумаги из RuData
--                                  'outDirectRepo'          VALUE SaleREPOAmount,        -- Количество ц/б, переданных по сделкам прямого репо
--                                  'outLoan'                VALUE TransLoanAmount,       -- Количество ц/б, переданных по сделкам займа
--                                  'inRevRepo'              VALUE BuyREPOAmount,         -- Количество ц/б, полученных по сделкам обратного репо
--                                  'inLoan'                 VALUE AcceptLoanAmount,      -- Количество ц/б, полученных по сделкам займа
--                                  'outPeledgeCredOgr'      VALUE TransPledgeBOAmount,   -- Количество ц/б, переданных в залог по обязательствам кредитной организации
--                                  'outPeledgeThirdParty'   VALUE TransPledgeAmount,     -- Количество ц/б, переданных в залог по обязательствам третьих лиц
--                                  'inPeledge'              VALUE AcceptPledgeAmount,    -- Количество ц/б, принятых в залог
-- --                                пока поле отсутствует в базовом отчёте  'ecoCodeOut'             VALUE ecoCodeOut,            -- Код принадлежности контрагента к сектору экономики по сделкам займа ценных бумаг (переданных)
-- --                                пока поле отсутствует в базовом отчёте  'ecoCodeIn'              VALUE ecoCodeIn,             --  Код принадлежности контрагента к сектору экономики по сделкам займа ценных бумаг (полученных)
--                                  'note'                   VALUE note                   -- Примечание
--                          ) RETURNING CLOB
--                  )
--       )
--       INTO v_json_output
--       FROM (
--                SELECT
--                    orderNum,
--                    counter,
--                    Account,
--                    IssuerName,
--                    IssuerINN,
--                    IssuerOGRN,
--                    IssuerCountryCode,
--                    Code711,
--                    LSIN,
--                    ISIN,
--                    CFICode,
--                    FaceValueFICode,
--                    FaceValue,
--                    FaceValuePoint,
--                    RUD_FaceValue AS FaceValueRuData,
--                    SaleREPOAmount,
--                    TransLoanAmount,
--                    BuyREPOAmount,
--                    AcceptLoanAmount,
--                    TransPledgeBOAmount,
--                    TransPledgeAmount,
--                    AcceptPledgeAmount,
--                    note
--                FROM base_report
--                UNION ALL
--                SELECT
--                    orderNum,
--                    counter,
--                    Account,
--                    IssuerName,
--                    IssuerINN,
--                    IssuerOGRN,
--                    IssuerCountryCode,
--                    Code711,
--                    LSIN,
--                    ISIN,
--                    CFICode,
--                    FaceValueFICode,
--                    FaceValue,
--                    FaceValuePoint,
--                    FaceValueRuData,
--                    SaleREPOAmount,
--                    TransLoanAmount,
--                    BuyREPOAmount,
--                    AcceptLoanAmount,
--                    TransPledgeBOAmount,
--                    TransPledgeAmount,
--                    AcceptPledgeAmount,
--                    note
--                FROM details_report
--                UNION ALL
--                -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
--                SELECT NULL, NULL, NULL, NULL,
--                       NULL, NULL, NULL, NULL, NULL,
--                       NULL, NULL, NULL, NULL, NULL, NULL,
--                       NULL, NULL, NULL, NULL,
--                       NULL, NULL, NULL, NULL
--                FROM dual
--                WHERE NOT EXISTS (SELECT 1 FROM base_report)
--                ORDER BY orderNum
--            );
--
--       v_json_output := BuildSplitJsonOutput(p_trace_id_input => p_trace_id_input,
--                                             p_json_input => v_json_output,
--                                             p_report_date_input => p_date_from,
--                                             p_report_tag => C_REPORT_NAME_TAG,
--                                             p_items_arr_tag => C_ITEMS_ARR_TAG,
--                                             p_template_name => C_TEMPLATE_NAME,
--                                             p_output_file_name => C_OUTPUT_FILE_NAME,
--                                             p_s3_file_name => C_S3_FILE_NAME,
--                                             p_report_date_format => 'YYYY_MM');
--
--       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Построение отчёта успешно завершено: Расшифровка отчёта БР по форме №0409711, Раздел 3', it_log.C_MSG_TYPE__DEBUG);
--       RETURN v_json_output;
--
--       EXCEPTION
--           WHEN OTHERS THEN
--               -- Если массив ошибок пустой, но мы всё равно сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--   END Decrypt711Part3;
--
--
--   -------------------------------------------------------------------------------
--   ----- Формирование Расшифровки отчёта БР по форме 0409711 -----
--   -------------------------------------------------------------------------------
--   FUNCTION Decrypt711ReportRun_RC_ReportRun(p_trace_id_input VARCHAR2,
--                                             p_json_input CLOB,
--                                             p_is_production CHAR DEFAULT '1' -- Флаг для режима прода
--   )
--       RETURN CLOB
--   IS
--       -- Константы - Входной JSON
--       C_IN_PERIOD_TAG         CONSTANT VARCHAR2(32) := 'period';
--       C_IN_YEAR_TAG           CONSTANT VARCHAR2(32) := 'year';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8) := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(64) := 'СОФР не смог сформировать отчет: другая ошибка';
--
--       -- Переменные
--       v_period       INTEGER;
--       v_year         INTEGER;
--       v_rd_from      DATE;
--       v_rd_to        DATE;
--
--
--       v_part1_3 CLOB;
--       v_part3  CLOB;
--       v_part1_3_length INTEGER;
--       v_part3_length  INTEGER;
--       v_dest_offset  INTEGER;
--       v_json_obj     JSON_OBJECT_T;
--       v_rd           DATE;
--       v_has_args     BOOLEAN := FALSE;
--       v_errors_array JSON_ARRAY_T := JSON_ARRAY_T();
--
--       v_json_output   CLOB;
--   BEGIN
--       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Расшифровка отчёта БР по форме №0409711', it_log.C_MSG_TYPE__DEBUG);
--
--       -- Парсим входной JSON
--       v_json_obj := JSON_OBJECT_T.parse(p_json_input);
--       v_period := v_json_obj.get_string(C_IN_PERIOD_TAG);
--       v_year := v_json_obj.get_string(C_IN_YEAR_TAG);
--       v_rd_from := CASE WHEN v_year IS NOT NULL AND v_period IS NOT NULL
--                        THEN TO_DATE(v_year || '.' || v_period, 'YYYY.MM')
--                    END;
--       v_rd_to := CASE WHEN v_rd_from IS NOT NULL
--                      THEN LAST_DAY(v_rd_from)
--                  END;
--
--       -- Если нет даты, отдаем мета-данные формы
--       v_has_args := v_rd_from IS NOT NULL;
--       IF NOT v_has_args THEN
--           it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Дата отчёта не указана, возвращаем Meta UI формы: Расшифровка отчёта БР по форме №0409711', it_log.C_MSG_TYPE__DEBUG);
--           RETURN BuildJsonOutput(p_body => Decrypt711ReportMetaUI());
--       END IF;
--
--       DBMS_LOB.CREATETEMPORARY(v_json_output, FALSE);
-- --       v_part1_3 := Decrypt711Part1_3(p_trace_id_input, p_json_input, p_is_production);
--       v_part3 := Decrypt711Part3(p_trace_id_input, v_rd_from, v_rd_to);
--       return v_part3;
--
--       --       v_part1_3_length := DBMS_LOB.GETLENGTH(v_part1_3);
-- --       v_part3_length := DBMS_LOB.GETLENGTH(v_part3);
-- --
-- --       -- Копируем MoneyReport без последней скобки ']'
-- --       DBMS_LOB.COPY(v_json_output, v_part1_3, v_part1_3_length - 1, 1, 1);
-- --
-- --       -- Добавляем запятую
-- --       DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');
-- --
-- --       v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
-- --       -- Копируем DepoReport без первой '['
-- --       DBMS_LOB.COPY(v_json_output, v_part3, v_part3_length - 1, v_dest_offset, 2);
-- --
-- --       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Построение отчёта успешно завершено: Сверка остатков: СОФР-QUIK, Д/С и Ц/Б', it_log.C_MSG_TYPE__DEBUG);
-- --       RETURN v_json_output;
--
--       EXCEPTION
--           WHEN OTHERS THEN
--               -- Освобождаем ресурсы
--               IF DBMS_LOB.ISTEMPORARY(v_json_output) = 1 THEN
--                   DBMS_LOB.FREETEMPORARY(v_json_output);
--               END IF;
--
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--   END Decrypt711ReportRun_RC_ReportRun;


  /**************************************************************************************************\
  [Конец блока] BIQ-23781.5(intech), BIQ-29457.5(avt) Контроль за статусом и сроками представления отчетности в БР
  \**************************************************************************************************/

  /**************************************************************************************************\
  [Начало блока] BIQ-23781.3(intech), BIQ-29457.3(avt) Сверки записей внутреннего учета об остатках
  Изменения:
  --------------------------------------------------------------------------------------------------------------
  Дата        Автор            Jira                                    Описание
  ----------  ---------------  --------------------------------------  -----------------------------------------
  13.01.2026  Капустин Д.К.     BIQ-23781.3(intech), BIQ-29457.3(avt)   Создание

  \**************************************************************************************************/

  FUNCTION CASHBALANCES_RC_REPORTRUN(p_trace_id_input VARCHAR2, p_json_input CLOB,
                                     p_is_production CHAR DEFAULT '1') RETURN CLOB IS

      C_TEMPLATE_NAME CONSTANT      VARCHAR2(128) := 'get_money_report';
      C_OUTPUT_FILE_NAME CONSTANT   VARCHAR2(128) := 'Сверка_ВУ_БУ_ДС';
      C_S3_FILE_NAME CONSTANT       VARCHAR2(128) := 'cash_balances_report';
      C_REPORT_NAME_TAG CONSTANT    VARCHAR2(128) := 'getMoneyReport';
      C_ITEMS_ARR_TAG CONSTANT      VARCHAR2(128) := 'rest_info';

      -- Входной JSON
      C_IN_REPORT_DATE_TAG CONSTANT VARCHAR2(32)  := 'reportDate';
      C_IN_CLIENT_CODE_TAG CONSTANT VARCHAR2(32)  := 'clientCode';
      C_IN_CLIENT_NAME_TAG CONSTANT VARCHAR2(32)  := 'clientName';
      C_IN_CURR_CODE_TAG CONSTANT   VARCHAR2(32)  := 'currency';
      C_IN_DOC_NUMBER_TAG CONSTANT  VARCHAR2(32)  := 'docNumber'; -- Номер договора
      C_IN_DATE_FORMAT CONSTANT     VARCHAR2(32)  := 'YYYY-MM-DD';

      -- Константы - Ошибки
      C_ERR_02_CODE CONSTANT        VARCHAR2(8)   := 'ER_02';
      C_ERR_02_MSG CONSTANT         VARCHAR2(64)  := 'СОФР не смог сформировать отчет: клиент по ЕКК=''%s'' не найден';
      C_ERR_03_CODE CONSTANT        VARCHAR2(8)   := 'ER_03';
      C_ERR_03_MSG CONSTANT         VARCHAR2(64)  := 'СОФР не смог сформировать отчет: клиент по ФИО=''%s'' не найден';
      C_ERR_04_CODE CONSTANT        VARCHAR2(8)   := 'ER_04';
      C_ERR_04_MSG CONSTANT         VARCHAR2(64)  := 'СОФР не смог сформировать отчет: договор=''%s'' не найден';
      C_ERR_05_CODE CONSTANT        VARCHAR2(8)   := 'ER_05';
      C_ERR_05_MSG CONSTANT         VARCHAR2(64)  := 'СОФР не смог сформировать отчет: дата=''%s'' не валидна';
      C_ERR_06_CODE CONSTANT        VARCHAR2(8)   := 'ER_06';
      C_ERR_06_MSG CONSTANT         VARCHAR2(128) := 'СОФР не смог сформировать отчет: по запрошенным параметрам отсутствуют данные';
      C_ERR_99_CODE CONSTANT        VARCHAR2(8)   := 'ER_99';
      C_ERR_99_MSG CONSTANT         VARCHAR2(64)  := 'СОФР не смог сформировать отчет: другая ошибка';

      -- Параметры входного запроса
      v_rd                          DATE; -- Формальная дата отчёта (для отображения пользователю и наименования отчёта)
      v_client_code                 VARCHAR2(64); -- ЕКК клиента
      v_client_name                 VARCHAR2(120); -- ФИО или часть ФИО клиента
      v_curr_code_list              SYS.ODCIVARCHAR2LIST; -- Массив с кодами валют
      v_doc_number                  VARCHAR2(64); -- Номер договора

      -- Переменные
      v_json_obj                    JSON_OBJECT_T;
      v_has_args                    BOOLEAN       := FALSE;
      v_json_output                 CLOB;

      -- Валидация
      v_is_ekk_exists               CHAR(1)       := '0'; -- 1 - если ЕКК найден в СОФР или QUIK, иначе - 0
      v_is_fio_exists               CHAR(1)       := '0'; -- 1 - если ФИО найден в СОФР, иначе - 0
      v_is_doc_number_exists        CHAR(1)       := '0';
      v_is_date_invalid             CHAR(1)       := '0'; -- 1 - если дата не валидна
      v_is_all_checks_failed        CHAR(1)       := '0'; -- 1 - если по всем проверкам не нашлось данных
      v_errors_array                JSON_ARRAY_T  := JSON_ARRAY_T();
  BEGIN
      it_log.log('traceId=''' || p_trace_id_input || ''' ' ||
                 'Запущено построение отчёта: Сверки записей внутреннего учета об остатках: Д/С',
                 it_log.C_MSG_TYPE__DEBUG);

      -- Парсим входной JSON
      v_json_obj := JSON_OBJECT_T.parse(p_json_input);

      v_rd := TO_DATE(v_json_obj.get_string(C_IN_REPORT_DATE_TAG), C_IN_DATE_FORMAT);
      v_client_code := UPPER(v_json_obj.get_string(C_IN_CLIENT_CODE_TAG));
      v_client_name := UPPER(v_json_obj.get_string(C_IN_CLIENT_NAME_TAG));
      v_doc_number := UPPER(v_json_obj.get_string(C_IN_DOC_NUMBER_TAG));
      v_curr_code_list := IT_CHECKLIMITREPORT.GetArrayFromJsonField(p_json_input, C_IN_CURR_CODE_TAG);

      -- Если нет даты, отдаем мета-данные формы
      v_has_args := v_rd IS NULL;
      IF v_has_args THEN
          it_log.log('traceId=''' || p_trace_id_input || ''' ' ||
                     'Дата отчёта не указана, возвращаем Meta UI формы: Сверки записей внутреннего учета об остатках: Д/С',
                     it_log.C_MSG_TYPE__DEBUG);
          RETURN IT_CHECKLIMITREPORT.BuildJsonOutput(p_body => GETCASHBALANCESREPORTMETAUI());
      END IF;

      -- Логгируем, если не в проде
      IF (p_is_production = 0) THEN
          it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Парсинг входных параметров завершен',
                     it_log.C_MSG_TYPE__DEBUG,
                     'Параметры отчёта: ' ||
                     'report_date=' || TO_CHAR(v_rd, 'YYYY-MM-DD') || ', ' ||
                     'client_code=' || COALESCE(v_client_code, 'NULL') || ', ' ||
                     'client_name=' || COALESCE(v_client_name, 'NULL') || ', ' ||
                     'docNumber=' || COALESCE(v_doc_number, 'NULL') || ', ' ||
                     'curr_code_list_count=' || CASE
                                                    WHEN v_curr_code_list IS NULL THEN '0'
                                                    ELSE TO_CHAR(v_curr_code_list.COUNT)
                                                END);

      END IF;

      -- Валидация входных параметров
      -- Дата отчета в пределах допустимого
      SELECT CASE
                 WHEN v_rd > SYSDATE THEN 1
                 ELSE 0
             END
      INTO v_is_date_invalid
      FROM dual;

      -- Найдены счета с указанными ЕКК
      SELECT CASE
                 WHEN v_client_code IS NULL OR v_client_code = ''                                            THEN 1
                 WHEN EXISTS (SELECT 1 FROM DDL_CLIENTINFO_DBT rest WHERE UPPER(rest.t_ekk) = v_client_code) THEN 1
                 ELSE 0
             END
      INTO v_is_ekk_exists
      FROM dual;

      -- В СОФР существует клиент с введенным ФИО
      SELECT CASE
                 WHEN v_client_name IS NULL OR v_client_name = '' THEN 1
                 WHEN EXISTS (SELECT 1 FROM DPARTY_DBT cl WHERE UPPER(cl.t_name) LIKE '%' || v_client_name || '%')
                                                                  THEN 1
                 ELSE 0
             END
      INTO v_is_fio_exists
      FROM dual;

      -- В СОФР существует договор с номером
      SELECT CASE
                 WHEN v_doc_number IS NULL OR v_doc_number = '' THEN 1
                 WHEN EXISTS (SELECT 1
                              FROM dsfcontr_dbt dsf
                              WHERE ((UPPER(dsf.t_number) = UPPER(v_doc_number)) OR
                                     (UPPER(dsf.t_number) LIKE UPPER(v_doc_number || '\_%') ESCAPE '\')))
                                                                THEN 1
                 ELSE 0
             END
      INTO v_is_doc_number_exists
      FROM dual;

      -- Проверка всех полей вместе
      SELECT CASE
                 WHEN EXISTS (SELECT 1
                              FROM DDL_CLIENTINFO_DBT rest
                                       JOIN DPARTY_DBT party ON (party.T_PARTYID = rest.T_PARTYID)
                                       JOIN dsfcontr_dbt dsf ON (party.T_PARTYID = dsf.T_PARTYID)
                              WHERE ((v_client_code IS NULL) OR (UPPER(rest.t_ekk) = v_client_code))
                                AND ((v_client_name IS NULL) OR (UPPER(party.t_name) LIKE '%' || v_client_name || '%'))
                                AND ((v_doc_number IS NULL) OR ((UPPER(dsf.t_number) = UPPER(v_doc_number)) OR
                                                                (UPPER(dsf.t_number) LIKE UPPER(v_doc_number || '\_%') ESCAPE '\')))
                                AND (dsf.t_datebegin <= v_rd AND
                                     (dsf.t_dateclose = TO_DATE('01.01.0001', 'dd.mm.yyyy') OR dsf.t_dateclose >= v_rd))
                                AND ((NOT EXISTS (SELECT 1 FROM TABLE (v_curr_code_list))) OR
                                     (dsf.T_FIID IN (SELECT COLUMN_VALUE FROM TABLE (v_curr_code_list))))) THEN '1'
                 ELSE '0'
             END
      INTO v_is_all_checks_failed
      FROM dual;

      IF (v_is_date_invalid = '1') THEN
          v_errors_array.append(IT_CHECKLIMITREPORT.GetErrorObjAndLog(p_trace_id_input, C_ERR_05_CODE,
                                                                      UTL_LMS.FORMAT_MESSAGE(C_ERR_05_MSG, TO_CHAR(v_rd, 'dd.MM.yyyy'))));
      END IF;

      IF (v_is_ekk_exists = '0') THEN
          v_errors_array.append(IT_CHECKLIMITREPORT.GetErrorObjAndLog(p_trace_id_input, C_ERR_02_CODE,
                                                                      UTL_LMS.FORMAT_MESSAGE(C_ERR_02_MSG, v_client_code)));
      END IF;
      IF (v_is_fio_exists = '0') THEN
          v_errors_array.append(IT_CHECKLIMITREPORT.GetErrorObjAndLog(p_trace_id_input, C_ERR_03_CODE,
                                                                      UTL_LMS.FORMAT_MESSAGE(C_ERR_03_MSG, v_client_name)));
      END IF;

      IF (v_is_doc_number_exists = '0') THEN
          v_errors_array.append(IT_CHECKLIMITREPORT.GetErrorObjAndLog(p_trace_id_input, C_ERR_04_CODE,
                                                                      UTL_LMS.FORMAT_MESSAGE(C_ERR_04_MSG, v_doc_number)));
      END IF;

      IF (v_is_all_checks_failed = '0') THEN
          v_errors_array.append(IT_CHECKLIMITREPORT.GetErrorObjAndLog(p_trace_id_input, C_ERR_06_CODE,
                                                                      C_ERR_06_MSG));
      END IF;

      IF (v_errors_array.get_size() > 0) THEN
          RAISE NO_DATA_FOUND;
      END IF;

      WITH ekk_req    AS (SELECT c.t_code t_ekk, m.t_sfcontrid
                          FROM ddlcontrmp_dbt m
                                   JOIN ddlobjcode_dbt c
                                        ON c.t_objectid = m.t_dlcontrid
                                            AND c.t_objecttype = 207
                                            AND c.t_codekind = 1),
           inacc_req  AS (SELECT *
                          FROM (SELECT t.*,
                                       ROW_NUMBER() OVER (
                                           PARTITION BY (CASE
                                                             WHEN ((T_LEGALFORM = 2) AND (SUBSTR(T_ACCOUNT, 0, 2) = '27'))
                                                                 THEN REGEXP_REPLACE(contr_number, '_(ф|v|с)$', '')
                                                             ELSE contr_number
                                                         END), T_ACCOUNT
                                           ORDER BY CASE
                                                        WHEN (T_LEGALFORM = 2) AND (SUBSTR(T_ACCOUNT, 0, 2) = '27') AND
                                                             (SUBSTR(contr_number, -2) = '_ф') THEN 1
                                                        WHEN (T_LEGALFORM = 2) AND (SUBSTR(T_ACCOUNT, 0, 2) = '27') AND
                                                             (SUBSTR(contr_number, -2) = '_v') THEN 2
                                                        WHEN (T_LEGALFORM = 2) AND (SUBSTR(T_ACCOUNT, 0, 2) = '27') AND
                                                             (SUBSTR(contr_number, -2) = '_c') THEN 3
                                                        ELSE 1
                                                    END
                                           ) AS rn
                                FROM (SELECT inacc.T_ACCOUNT, inacc.T_CURRENCY, inacc.t_owner, inacc.t_clientcontrid,
                                             inacc.t_templnum, contr.T_NUMBER AS contr_number, party.T_LEGALFORM,
                                             party.T_PARTYID AS PARTYID,
                                             contr.T_ID AS CONTRID, party.T_NAME AS PARTYNAME,
                                             contr.t_datebegin AS contr_date_begin
                                      FROM dmcaccdoc_dbt inacc
                                               LEFT JOIN DACCOUNT_DBT acc ON (inacc.T_ACCOUNT = acc.T_ACCOUNT)
                                               LEFT JOIN dsfcontr_dbt contr ON (inacc.T_CLIENTCONTRID = contr.T_ID)
                                               LEFT JOIN DPARTY_DBT party ON (party.T_PARTYID = contr.T_PARTYID)
                                      WHERE inacc.t_catID = 349
                                        AND (acc.T_CLOSE_DATE = TO_DATE('1-1-1', 'dd-mm-yyyy') OR
                                             acc.T_CLOSE_DATE > v_rd)
                                        AND ((party.T_LEGALFORM = 1 AND
                                              (SUBSTR(inacc.T_ACCOUNT, 0, 2) = '21' OR
                                               SUBSTR(inacc.T_ACCOUNT, 0, 2) = '23' OR
                                               SUBSTR(inacc.T_ACCOUNT, 0, 2) = '26'))
                                          OR (party.T_LEGALFORM = 2 AND
                                              (SUBSTR(inacc.T_ACCOUNT, 0, 2) = '21' OR
                                               SUBSTR(inacc.T_ACCOUNT, 0, 2) = '27')))
                                        AND (party.T_LEGALFORM <> 2 OR SUBSTR(inacc.T_ACCOUNT, 0, 2) <> '27' OR
                                             SUBSTR(contr.T_NUMBER, -2) = '_ф' OR SUBSTR(contr.T_NUMBER, -2) = '_v' OR
                                             SUBSTR(contr.T_NUMBER, -2) = '_c')
                                        AND contr.t_datebegin <= v_rd AND (
                                          contr.t_dateclose = TO_DATE('01.01.0001', 'dd.mm.yyyy') OR
                                          contr.t_dateclose >= v_rd)
                                        AND ((v_doc_number IS NULL) OR
                                             ((UPPER(contr.t_number) = UPPER(v_doc_number)) OR
                                              (UPPER(contr.t_number) LIKE UPPER(v_doc_number || '\_%') ESCAPE '\')))) t)
                          WHERE rn = 1),
           gbacc_req  AS (SELECT gbacc.T_ACCOUNT, gbacc.T_CURRENCY, gbacc.t_owner, gbacc.t_clientcontrid
                          FROM dmcaccdoc_dbt gbacc
                                   LEFT JOIN DACCOUNT_DBT acc ON (gbacc.T_ACCOUNT = acc.T_ACCOUNT)
                          WHERE gbacc.t_catID = 70
                            AND gbacc.t_disablingdate = TO_DATE('1-1-1', 'dd-mm-yyyy')
                            AND (acc.T_CLOSE_DATE = TO_DATE('1-1-1', 'dd-mm-yyyy') OR acc.T_CLOSE_DATE > v_rd)
                            AND gbacc.t_iscommon = 'X'),
           req_result AS (SELECT inacc.PARTYNAME AS T_OWNER_NAME,
                                 inacc.contr_number AS T_CONTRACT_NUMBER,
                                 MAX(inacc.contr_date_begin) AS T_CONTRACT_DATE_BEGIN,
                                 finins.T_CCY AS CUR_CODE,
                                 inacc.T_ACCOUNT AS T_ACCOUNT_VU_NUMBER,
                                 gbacc.T_ACCOUNT AS T_ACCOUNT_DU_NUMBER,
                                 T_REST_VU.val AS T_REST_VU,
                                 CONVERT_SUM_TO_RUB_BY_DATE_PROXY(v_rd, T_REST_VU.val,
                                                                                               inacc.T_CURRENCY) AS t_rest_rub_vu,
                                 T_REST_DU.val AS T_REST_DU,
                                 CONVERT_SUM_TO_RUB_BY_DATE_PROXY(v_rd, T_REST_DU.val,
                                                                                               inacc.T_CURRENCY) AS t_rest_rub_du
                          FROM inacc_req inacc
                                   JOIN gbacc_req gbacc ON (gbacc.t_owner = inacc.PARTYID
                              AND gbacc.t_clientcontrid = inacc.CONTRID
                              AND inacc.T_CURRENCY = gbacc.T_CURRENCY
                              AND SUBSTR(gbacc.T_ACCOUNT, 14, 7) = SUBSTR(inacc.T_ACCOUNT, 10, 7))
                                   LEFT JOIN DFININSTR_DBT finins
                                             ON (FININS.T_FIID = inacc.T_CURRENCY)
                                   LEFT JOIN ekk_req ekk
                                             ON ekk.t_sfcontrid = inacc.CONTRID
                                   CROSS APPLY (SELECT COALESCE(
                                                         rsb_account.restall(inacc.T_ACCOUNT, 21, inacc.T_CURRENCY, v_rd),
                                                         0) AS val
                                                FROM DUAL) T_REST_VU
                                   CROSS APPLY (SELECT COALESCE(
                                                         rsb_account.restall(gbacc.T_ACCOUNT, 1, gbacc.T_CURRENCY, v_rd),
                                                         0) AS val
                                                FROM DUAL) T_REST_DU
                          WHERE ((v_client_code IS NULL) OR (ekk.T_EKK = v_client_code))
                            AND (v_client_name IS NULL OR v_client_name = '' OR
                                 UPPER(inacc.PARTYNAME) LIKE '%' || v_client_name || '%')
                            AND ((NOT EXISTS (SELECT 1 FROM TABLE (v_curr_code_list))) OR
                                 (inacc.T_CURRENCY IN (SELECT COLUMN_VALUE FROM TABLE (v_curr_code_list))))
                          GROUP BY inacc.PARTYID, inacc.PARTYNAME, inacc.contr_number, finins.T_CCY, inacc.T_ACCOUNT
                                 , gbacc.T_ACCOUNT, inacc.T_CURRENCY, gbacc.T_CURRENCY, T_REST_VU.val, T_REST_DU.val)
      SELECT (
                 JSON_ARRAYAGG(
                   JSON_OBJECT(
                     'owner_name' VALUE T_OWNER_NAME,
                     'contract_number' VALUE T_CONTRACT_NUMBER,
                     'contract_date_begin' VALUE T_CONTRACT_DATE_BEGIN,
                     'cur_type' VALUE CUR_CODE,
                     'account_vu' VALUE T_ACCOUNT_VU_NUMBER,
                     'account_du' VALUE T_ACCOUNT_DU_NUMBER,
                     'rest_vu' VALUE T_REST_VU,
                     'rest_rub_vu' VALUE t_rest_rub_vu,
                     'rest_du' VALUE T_REST_DU,
                     'rest_rub_du' VALUE t_rest_rub_du
                   ) RETURNING CLOB
                 )
                 )
      INTO v_json_output
      FROM (SELECT r.*
            FROM req_result r
            UNION ALL
            -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
            SELECT NULL, NULL, NULL, NULL, NULL,
                   NULL, NULL, NULL, NULL, NULL
            FROM dual
            WHERE NOT EXISTS (SELECT 1 FROM req_result));

      v_json_output := IT_CHECKLIMITREPORT.BuildSplitJsonOutput(p_trace_id_input => p_trace_id_input,
                                                                p_json_input => v_json_output,
                                                                p_report_date_input => v_rd,
                                                                p_report_tag => C_REPORT_NAME_TAG,
                                                                p_items_arr_tag => C_ITEMS_ARR_TAG,
                                                                p_template_name => C_TEMPLATE_NAME,
                                                                p_output_file_name => C_OUTPUT_FILE_NAME,
                                                                p_s3_file_name => C_S3_FILE_NAME);

      it_log.log('traceId=''' || p_trace_id_input || ''' ' ||
                 'Построение отчёта успешно завершено: Сверки записей внутреннего учета об остатках: Д/С',
                 it_log.C_MSG_TYPE__DEBUG);
      RETURN v_json_output;

  EXCEPTION
      WHEN OTHERS THEN
          -- Если массив ошибок пустой, но мы всё равно сюда попали, значит произошло что-то непредвиденное
          it_error.put_error_in_stack;
          IF (v_errors_array.get_size() = 0) THEN
              v_errors_array.append(IT_CHECKLIMITREPORT.GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                                          C_ERR_99_MSG || ':' || SQLCODE || ' ' ||
                                                                          SQLERRM));
          END IF;

          RETURN IT_CHECKLIMITREPORT.BuildJsonOutput(p_errors_array => v_errors_array);

  END CASHBALANCES_RC_REPORTRUN;

  --- UI
  FUNCTION GETCASHBALANCESREPORTMETAUI RETURN CLOB IS
      C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
      C_REPORT_LOCALIZED_NAME VARCHAR2(64)  := 'Сверки записей внутреннего учета об остатках: Д/С';
      C_SYS_TAGS              VARCHAR2(256) := '["ORACLE", "Balance"]';
      v_meta_ui               CLOB;
  BEGIN
      WITH currencies AS (SELECT finins.T_FIID AS cur_id, FININS.T_CCY AS cur_code
                          FROM DFININSTR_DBT finins
                          WHERE finins.T_FI_KIND = 1
                            AND EXISTS (SELECT 1 FROM dsettacc_dbt ss WHERE ss.T_FIID = FININS.T_FIID))
      SELECT JSON_OBJECT(
               C_META_UI_TAG__ROLES VALUE C_ROLES FORMAT JSON,
               C_META_UI_TAG__LABEL VALUE C_REPORT_LOCALIZED_NAME,
               C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
               C_META_UI_TAG__FORM VALUE JSON_ARRAY(
                   -- Первая строка
                 JSON_ARRAY(
                   JSON_OBJECT(
                     'label' VALUE 'Дата отчета',
                     'name' VALUE 'reportDate',
                     'type' VALUE 'date',
                     'required' VALUE 'true' FORMAT JSON,
                     'column' VALUE 0,
                     'default' VALUE TO_CHAR(SYSDATE - 1, 'YYYY-MM-DD')
                     RETURNING CLOB
                   ),
                   JSON_OBJECT(
                     'label' VALUE 'ЕКК клиента',
                     'name' VALUE 'clientCode',
                     'type' VALUE 'text',
                     'required' VALUE 'false' FORMAT JSON,
                     'column' VALUE 1,
                     'default' VALUE ''
                     RETURNING CLOB
                   )
                 ),
                   -- Вторая строка
                 JSON_ARRAY(
                   JSON_OBJECT(
                     'label' VALUE 'ФИО клиента',
                     'name' VALUE 'clientName',
                     'type' VALUE 'text',
                     'required' VALUE 'false' FORMAT JSON,
                     'column' VALUE 0,
                     'default' VALUE ''
                     RETURNING CLOB
                   ),
                   JSON_OBJECT(
                     'label' VALUE 'Номер договора',
                     'name' VALUE 'docNumber',
                     'type' VALUE 'text',
                     'required' VALUE 'false' FORMAT JSON,
                     'column' VALUE 1,
                     'default' VALUE ''
                     RETURNING CLOB
                   )
                 ),
                   -- Третья строка
                 JSON_ARRAY(
                   JSON_OBJECT(
                     'label' VALUE 'Валюта',
                     'name' VALUE 'currency',
                     'type' VALUE 'select',
                     'required' VALUE 'true' FORMAT JSON,
                     'column' VALUE 1,
                     'default' VALUE (SELECT JSON_ARRAYAGG(cur_id RETURNING CLOB)
                                      FROM currencies),
                     'multiselect' VALUE 'true' FORMAT JSON,
                     'items' VALUE (SELECT JSON_ARRAYAGG(
                                             JSON_OBJECT(
                                               'name' VALUE cur_code,
                                               'value' VALUE cur_id
                                             ) RETURNING CLOB
                                           )
                                    FROM currencies)
                     RETURNING CLOB
                   )
                 )
                                         ) RETURNING CLOB
             )
      INTO v_meta_ui
      FROM dual;

      RETURN v_meta_ui;
  END GETCASHBALANCESREPORTMETAUI;

  FUNCTION CONVERT_SUM_TO_RUB_BY_DATE_PROXY(convertDate DATE, curSum NUMBER, targetFIID NUMBER) RETURN NUMBER IS
      RUB_FIID           NUMBER := 0;
      CONVERT_SUM_RESULT NUMBER := 1;
      CONVERT_SUM_STATUS NUMBER := 0;
  BEGIN
      CONVERT_SUM_STATUS :=
        RSB_SPREPFUN.SmartConvertSum(CONVERT_SUM_RESULT, curSum, convertDate, targetFIID, RUB_FIID, 1);
      RETURN CONVERT_SUM_RESULT;
  END CONVERT_SUM_TO_RUB_BY_DATE_PROXY;

  /**************************************************************************************************\
  [Конец блока] BIQ-23781.3(intech), BIQ-29457.3(avt) Сверки записей внутреннего учета об остатках
  \**************************************************************************************************/

   /**************************************************************************************************\
    [Начало блока] BIQ-23781.3(intech), BIQ-29457.3(avt) Сверки записей внутреннего учета об остатках ц/б
    Изменения:
    --------------------------------------------------------------------------------------------------------------
    Дата        Автор            Jira                                    Описание
    ----------  ---------------  --------------------------------------  -----------------------------------------
    15.01.2026  Власов В.В.     BIQ-23781.3(intech), BIQ-29457.3(avt)   Создание

    \**************************************************************************************************/
    -- =============================================================================
    -- Валидация
    -- =============================================================================
--     FUNCTION ValidateDepoRestParams(
--       p_trace_id   VARCHAR2,
--       p_client_ekk VARCHAR2,
--       p_client_name VARCHAR2
--     ) RETURN JSON_ARRAY_T
--     IS
--       v_errors JSON_ARRAY_T := JSON_ARRAY_T();
--       v_cnt NUMBER;
--     BEGIN
--       -- Проверка клиента по ЕКК
--       IF p_client_ekk IS NOT NULL THEN
--         SELECT COUNT(*)
--         INTO v_cnt
--         FROM DDL_CLIENTINFO_DBT
--         WHERE T_EKK = p_client_ekk;
--
--         IF v_cnt = 0 THEN
--           v_errors.append(
--             IT_CHECKLIMITREPORT.GetErrorObjAndLog(
--               p_trace_id,
--               'ER_03',
--               'СОФР не смог сформировать отчет: клиент по ЕКК=''' ||
--               p_client_ekk || ''' не найден'
--             )
--           );
--         END IF;
--       END IF;
--
--       -- Проверка клиента по имени
--       IF p_client_name IS NOT NULL THEN
--         SELECT COUNT(*)
--         INTO v_cnt
--         FROM DPARTY_DBT
--         WHERE UPPER(T_NAME) LIKE '%' || UPPER(p_client_name) || '%';
--
--         IF v_cnt = 0 THEN
--           v_errors.append(
--             IT_CHECKLIMITREPORT.GetErrorObjAndLog(
--               p_trace_id,
--               'ER_02',
--               'СОФР не смог сформировать отчет: клиент по ФИО=''' ||
--               p_client_name || ''' не найден'
--             )
--           );
--         END IF;
--       END IF;
--
--       RETURN v_errors;
--     END ValidateDepoRestParams;
--
--     -- =============================================================================
--     -- Расхождения
--     -- =============================================================================
--     FUNCTION BuildDepoRestReason(
--       p_is_dead NUMBER,
--       p_cnt_issuer_names NUMBER,
--       p_cnt_broker_contracts NUMBER,
--       p_qty_vu NUMBER,
--       p_qty_bu NUMBER,
--       p_qty_depo NUMBER
--     ) RETURN VARCHAR2
--     IS
--       v_reason VARCHAR2(1000);
--     BEGIN
--       v_reason :=
--         CASE WHEN p_is_dead = 1
--           THEN 'Смерть депонента, ' END ||
--         CASE WHEN p_cnt_issuer_names > 1
--           THEN 'Два названия с одним ISIN, ' END ||
--         CASE WHEN p_qty_depo IS NULL
--           THEN 'СпецДепо, ' END ||
--         CASE WHEN p_cnt_broker_contracts > 1
--           THEN 'У клиента несколько договоров брокерского обслуживания, ' END ||
--         CASE WHEN p_qty_vu <> p_qty_bu
--           OR p_qty_vu <> NVL(p_qty_depo, p_qty_vu)
--           THEN 'Иные причины расхождения, ' END ||
--         CASE WHEN p_qty_vu = p_qty_bu
--           AND p_qty_vu = NVL(p_qty_depo, p_qty_vu)
--           AND p_is_dead = 0
--           AND p_cnt_issuer_names = 1
--           AND p_cnt_broker_contracts = 1
--           THEN 'Расхождения отсутствуют, ' END;
--
--       RETURN RTRIM(v_reason, ', ');
--     END BuildDepoRestReason;
--
--     -- =============================================================================
--     -- Данные отчёта
--     -- =============================================================================
--     FUNCTION BuildDepoRestDataJson(
--       p_report_date DATE,
--       p_client_ekk VARCHAR2,
--       p_client_name VARCHAR2,
--       p_contract_number VARCHAR2,
--       p_asset_type VARCHAR2,
--       p_isin VARCHAR2
--     ) RETURN CLOB
--     IS
--       v_json_rows CLOB;
--     BEGIN
--       WITH
--       -- ВУ
--       vu AS (
--         SELECT
--           cli.T_EKK client_code,
--           pcli.T_NAME client_name,
--           c.T_NUMBER contract_number,
--           c.T_DATEBEGIN contract_date,
--           fi.T_FIID,
--           fi.T_NAME asset_name,
--           av.T_NAME asset_type,
--           av.T_DEFINITION asset_category,
--           NVL(iss.T_SHORTNAME, iss.T_NAME) issuer_name,
--           r.T_REST qty_vu
--         FROM DRESTDATE_DBT r
--         JOIN DDL_CLIENTINFO_DBT cli
--           ON cli.T_ACCOUNTID = r.T_ACCOUNTID
--         JOIN DSFCONTR_DBT c
--           ON c.T_ID = cli.T_SFCONTRID
--         LEFT JOIN DFININSTR_DBT fi
--           ON fi.T_FIID = r.T_RESTCURRENCY
--         LEFT JOIN DAVRKINDS_DBT av
--           ON av.T_FI_KIND = fi.T_FI_KIND
--         LEFT JOIN DPARTY_DBT iss
--           ON iss.T_PARTYID = fi.T_ISSUER
--         LEFT JOIN DPARTY_DBT pcli
--           ON pcli.T_PARTYID = cli.T_CLIENT
--         WHERE r.T_RESTDATE = p_report_date
--           AND (p_client_ekk IS NULL OR cli.T_EKK = p_client_ekk)
--           AND (p_client_name IS NULL OR UPPER(pcli.T_NAME) LIKE '%' || UPPER(p_client_name) || '%')
--           AND (p_contract_number IS NULL OR c.T_NUMBER = p_contract_number)
--           AND (p_asset_type IS NULL OR av.T_NAME = p_asset_type)
--           AND (p_isin IS NULL OR fi.T_FIID = p_isin)
--       ),
--
--       -- БУ
--       bu AS (
--         SELECT
--           cli.T_EKK client_code,
--           c.T_NUMBER contract_number,
--           fi.T_FIID,
--           SUM(w.T_AMOUNT) qty_bu
--         FROM DPMWRTSUM_DBT w
--         JOIN DSFCONTR_DBT c
--           ON c.T_ID = w.T_CONTRACT
--         JOIN DDL_CLIENTINFO_DBT cli
--           ON cli.T_SFCONTRID = c.T_ID
--         JOIN DFININSTR_DBT fi
--           ON fi.T_FIID = w.T_FIID
--         WHERE w.T_CHANGEDATE <= p_report_date
--         GROUP BY cli.T_EKK, c.T_NUMBER, fi.T_FIID
--       ),
--
--       -- Депо
--       depo AS (
--         SELECT
--           acc.T_DEPONUMBER contract_number,
--           isin.T_ID T_FIID,
--           d.VALUE qty_depo
--         FROM DDIASRESTDEPO_DBT d
--         JOIN DDIASACCDEPO_DBT acc
--           ON acc.T_SOFRACCID = d.ACCDEPOID
--         JOIN DDIASISIN_DBT isin
--           ON isin.T_ID = d.ISIN
--         WHERE d.REPORTDATE = p_report_date
--       ),
--
--       death AS (
--         SELECT cli.T_EKK client_code
--         FROM DPERSN_DBT p
--         JOIN DDL_CLIENTINFO_DBT cli
--           ON cli.T_CLIENT = p.T_PERSONID
--         WHERE p.T_DEATH IS NOT NULL
--       ),
--
--       issuer_cnt AS (
--         SELECT
--           client_code,
--           T_FIID,
--           COUNT(DISTINCT issuer_name) cnt_issuer_names
--         FROM vu
--         GROUP BY client_code, T_FIID
--       ),
--
--       broker_contracts AS (
--         SELECT
--           client_code,
--           T_FIID,
--           COUNT(DISTINCT contract_number) cnt_broker_contracts
--         FROM vu
--         GROUP BY client_code, T_FIID
--       ),
--
--       agg AS (
--         SELECT
--           v.client_code,
--           v.client_name,
--           v.contract_number,
--           v.contract_date,
--           v.asset_type,
--           v.asset_category,
--           v.asset_name,
--           v.issuer_name,
--           v.qty_vu,
--           NVL(b.qty_bu, 0) qty_bu,
--           d.qty_depo,
--           NVL(ic.cnt_issuer_names, 1) cnt_issuer_names,
--           NVL(bc.cnt_broker_contracts, 1) cnt_broker_contracts,
--           CASE WHEN dc.client_code IS NOT NULL THEN 1 ELSE 0 END is_dead
--         FROM vu v
--         LEFT JOIN bu b
--           ON b.client_code = v.client_code
--          AND b.contract_number = v.contract_number
--          AND b.T_FIID = v.T_FIID
--         LEFT JOIN depo d
--           ON d.contract_number = v.contract_number
--          AND d.T_FIID = v.T_FIID
--         LEFT JOIN death dc
--           ON dc.client_code = v.client_code
--         LEFT JOIN issuer_cnt ic
--           ON ic.client_code = v.client_code
--          AND ic.T_FIID = v.T_FIID
--         LEFT JOIN broker_contracts bc
--           ON bc.client_code = v.client_code
--          AND bc.T_FIID = v.T_FIID
--       )
--       SELECT JSON_ARRAYAGG(
--                JSON_OBJECT(
--                  'client_code' VALUE client_code,
--                  'client_name' VALUE client_name,
--                  'contract_number' VALUE contract_number,
--                  'contract_date' VALUE TO_CHAR(contract_date, 'YYYY-MM-DD'),
--                  'asset_type' VALUE asset_type,
--                  'asset_category' VALUE asset_category,
--                  'asset_name' VALUE asset_name,
--                  'issuer_name' VALUE issuer_name,
--                  'qty_vu' VALUE qty_vu,
--                  'qty_depo' VALUE qty_depo,
--                  'qty_bu' VALUE qty_bu,
--                  'reason' VALUE BuildDepoRestReason(
--                    is_dead,
--                    cnt_issuer_names,
--                    cnt_broker_contracts,
--                    qty_vu,
--                    qty_bu,
--                    qty_depo
--                  )
--                ) RETURNING CLOB
--              )
--       INTO v_json_rows
--       FROM agg;
--
--       IF v_json_rows IS NULL THEN
--         v_json_rows := '[]';
--       END IF;
--
--       RETURN v_json_rows;
--     END BuildDepoRestDataJson;
--
--     -- =============================================================================
--     -- Основная функция
--     -- =============================================================================
--     FUNCTION DepoRest_RC_ReportRun (
--       p_trace_id_input VARCHAR2,
--       p_json_input CLOB,
--       p_is_production CHAR DEFAULT '1'
--     ) RETURN CLOB
--     IS
--       C_TEMPLATE_NAME CONSTANT VARCHAR2(128) := 'sofr_restdp';
--       C_OUTPUT_FILE_NAME CONSTANT VARCHAR2(128) := 'Сверка_остатков_цб_';
--       C_S3_FILE_NAME CONSTANT VARCHAR2(128) := 'restdp_report_';
--       C_REPORT_TAG CONSTANT VARCHAR2(128) := 'GetRestDepoReport';
--       C_ITEMS_ARR_TAG CONSTANT VARCHAR2(128) := 'Rest_info';
--       C_DATE_FMT CONSTANT VARCHAR2(20) := 'YYYY-MM-DD';
--
--       v_json_obj JSON_OBJECT_T;
--       v_report_date DATE;
--       v_client_ekk VARCHAR2(64);
--       v_client_name VARCHAR2(120);
--       v_contract_number VARCHAR2(150);
--       v_asset_type VARCHAR2(50);
--       v_isin VARCHAR2(25);
--
--       v_errors_array JSON_ARRAY_T := JSON_ARRAY_T();
--       v_json_rows CLOB;
--     BEGIN
--       it_log.log(
--         'traceId=''' || p_trace_id_input ||
--         ''' Старт отчета "Сверка остатков ЦБ"',
--         it_log.C_MSG_TYPE__DEBUG
--       );
--
--       v_json_obj := JSON_OBJECT_T.parse(p_json_input);
--
--       v_report_date := TO_DATE(v_json_obj.get_string('reportDate'), C_DATE_FMT);
--       v_client_ekk := v_json_obj.get_string('clientCode');
--       v_client_name := v_json_obj.get_string('clientName');
--       v_contract_number := v_json_obj.get_string('contractNumber');
--       v_asset_type := v_json_obj.get_string('assetType');
--       v_isin := v_json_obj.get_string('isin');
--
--       IF v_report_date IS NULL THEN
--         RETURN IT_CHECKLIMITREPORT.BuildJsonOutput(p_body => IT_CHECKLIMITREPORT.GetDepoReportMetaUI());
--       END IF;
--
--       v_errors_array := ValidateDepoRestParams(
--         p_trace_id => p_trace_id_input,
--         p_client_ekk => v_client_ekk,
--         p_client_name => v_client_name
--       );
--
--       IF v_errors_array.get_size() > 0 THEN
--         RETURN IT_CHECKLIMITREPORT.BuildJsonOutput(p_errors_array => v_errors_array);
--       END IF;
--
--       v_json_rows := BuildDepoRestDataJson(
--         v_report_date,
--         v_client_ekk,
--         v_client_name,
--         v_contract_number,
--         v_asset_type,
--         v_isin
--       );
--
--       RETURN IT_CHECKLIMITREPORT.BuildSplitJsonOutput(
--         p_trace_id_input,
--         v_json_rows,
--         v_report_date,
--         C_REPORT_TAG,
--         C_ITEMS_ARR_TAG,
--         C_TEMPLATE_NAME,
--         C_OUTPUT_FILE_NAME,
--         C_S3_FILE_NAME
--       );
--
--     EXCEPTION
--       WHEN OTHERS THEN
--         it_error.put_error_in_stack;
--
--         IF v_errors_array.get_size() = 0 THEN
--           v_errors_array.append(
--             IT_CHECKLIMITREPORT.GetErrorObjAndLog(
--               p_trace_id_input,
--               'ER_99',
--               'СОФР не смог сформировать отчет: другая ошибка. ' ||
--               SQLCODE || ' ' || SQLERRM
--             )
--           );
--         END IF;
--
--         RETURN IT_CHECKLIMITREPORT.BuildJsonOutput(p_errors_array => v_errors_array);
--     END DepoRest_RC_ReportRun;
--
--     /**************************************************************************************************\
--     [Конец блока] BIQ-23781.3(intech), BIQ-29457.3(avt) Сверки записей внутреннего учета об остатках ц/б
--     \**************************************************************************************************/

  /**************************************************************************************************\
  [Начало блока] BIQ-23781.5(intech), BIQ-29457.5(avt) Расшифровка отчетной формы 0409706

  Изменения:
  --------------------------------------------------------------------------------------------------------------
  Дата        Автор            Jira                                    Описание
  ----------  ---------------  --------------------------------------  -----------------------------------------
  11.03.2026  Капустин Д.К.     BIQ-23781.5(intech), BIQ-29457.5(avt)   Создание

  \**************************************************************************************************/

  FUNCTION DECRYPT706_RC_REPORTRUN(p_trace_id_input VARCHAR2, p_json_input CLOB,
                                   p_is_production CHAR DEFAULT '1') RETURN CLOB IS
      -- Входной JSON
      C_IN_REPORT_PERIOD_TAG CONSTANT VARCHAR2(32) := 'period';
      C_IN_YEAR_TAG CONSTANT          VARCHAR2(32) := 'year';

      -- Константы - Ошибки
      C_ERR_02_CODE CONSTANT          VARCHAR2(8)  := 'ER_02';
      C_ERR_02_MSG CONSTANT           VARCHAR2(64) := 'СОФР не смог сформировать отчет: нет данных на отчетный период';
      C_ERR_99_CODE CONSTANT          VARCHAR2(8)  := 'ER_99';
      C_ERR_99_MSG CONSTANT           VARCHAR2(64) := 'СОФР не смог сформировать отчет: другая ошибка';

      -- Параметры входного запроса
      v_period                        VARCHAR2(64); -- Период формирования отчета
      v_year                          VARCHAR2(64); -- Год отчета
      v_period_str                    VARCHAR2(120);

      -- Переменные
      v_json_obj                      JSON_OBJECT_T;
      v_has_args                      BOOLEAN      := FALSE;
      v_json_chapter_1_1              CLOB;
      v_json_chapter_1_2              CLOB;
      v_json_chapter_2_1              CLOB;
      v_json_output                   CLOB;
      v_int_period                    INT;
      v_start_date                    DATE;
      v_end_date                      DATE;
      v_prepare_result                INT;

      -- Валидация
      v_is_period_valid               CHAR(1)      := '0'; -- 1 - Период валидный, иначе - 0
      v_is_year_valid                 CHAR(1)      := '0'; -- 1 - Год валиден, иначе - 0
      v_errors_array                  JSON_ARRAY_T := JSON_ARRAY_T();
  BEGIN
      it_log.log('traceId=''' || p_trace_id_input || ''' ' ||
                 'Запущено построение отчёта: Расшифровка отчетной формы 0409706',
                 it_log.C_MSG_TYPE__DEBUG);

      -- Парсим входной JSON
      v_json_obj := JSON_OBJECT_T.parse(p_json_input);

      v_period := UPPER(v_json_obj.get_string(C_IN_REPORT_PERIOD_TAG));
      v_year := UPPER(v_json_obj.get_string(C_IN_YEAR_TAG));

      -- Если нет даты, отдаем мета-данные формы
      v_has_args := v_year IS NULL;
      IF v_has_args THEN
          it_log.log('traceId=''' || p_trace_id_input || ''' ' ||
                     'Дата отчёта не указана, возвращаем Meta UI формы: Расшифровка отчетной формы 0409706',
                     it_log.C_MSG_TYPE__DEBUG);
          RETURN IT_CHECKLIMITREPORT.BuildJsonOutput(p_body => GETDECRYPT706METAUI());
      END IF;

      -- Логгируем, если не в проде
      IF (p_is_production = 0) THEN
          it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Парсинг входных параметров завершен',
                     it_log.C_MSG_TYPE__DEBUG,
                     'Параметры отчёта: ' ||
                     'period=' || COALESCE(v_period, 'NULL') || ', ' ||
                     'year=' || COALESCE(v_year, 'NULL'));

      END IF;

      -- Валидация входных параметров
      SELECT CASE
                 WHEN EXISTS (SELECT 1 FROM TABLE (C_PERIOD) WHERE UPPER(v_period) = UPPER(COLUMN_VALUE)) THEN '1'
                 ELSE '0'
             END
      INTO v_is_period_valid
      FROM DUAL;

      SELECT CASE
                 WHEN EXISTS (SELECT years
                              FROM (SELECT TO_CHAR(EXTRACT(YEAR FROM SYSDATE) - LEVEL + 1) AS years
                                    FROM dual
                                    CONNECT BY LEVEL <= 10)
                              WHERE v_year = years) THEN '1'
                 ELSE '0'
             END
      INTO v_is_year_valid
      FROM dual;

      IF (v_is_period_valid = '0') THEN
          v_errors_array.append(IT_CHECKLIMITREPORT.GetErrorObjAndLog(p_trace_id_input, C_ERR_02_CODE,
                                                                      C_ERR_02_MSG));
      END IF;

      IF (v_is_year_valid = '0') THEN
          v_errors_array.append(IT_CHECKLIMITREPORT.GetErrorObjAndLog(p_trace_id_input, C_ERR_02_CODE,
                                                                      C_ERR_02_MSG));
      END IF;

      IF (v_errors_array.get_size() > 0) THEN
          RAISE NO_DATA_FOUND;
      END IF;

      FOR i IN 1..C_PERIOD.COUNT LOOP
          IF (UPPER(C_PERIOD(i)) = UPPER(v_period)) THEN
              v_int_period := i;
          END IF;
      END LOOP;
      -- Определяем периоды отчета
      IF (v_int_period BETWEEN 1 AND 12) THEN
          v_start_date := TO_DATE(v_year || LPAD(v_int_period, 2, '0') || '01', 'yyyyMMdd');
          v_end_date := LAST_DAY(v_start_date);
      ELSE
          v_start_date := TO_DATE(v_year || LPAD((v_int_period - 13) * 3 + 1, 2, '0') || '01',
                                  'yyyyMMdd'); -- первый квартал = 13, (13-13)*3+1 = январь, (14-13)*3+1 = апрель
          v_end_date := LAST_DAY(ADD_MONTHS(v_start_date, 2));
      END IF;

      v_period_str := v_period || ' ' || v_year || ' г.';
      v_json_chapter_1_1 :=
        GENERATE_DECRYPT_706_REPORT_CHAPTER_1_1(v_start_date, v_end_date, v_period_str, p_trace_id_input);
      v_json_chapter_1_2 :=
        GENERATE_DECRYPT_706_REPORT_CHAPTER_1_2(v_start_date, v_end_date, v_period_str, p_trace_id_input);
      v_json_chapter_2_1 :=
        GENERATE_DECRYPT_706_REPORT_CHAPTER_2_1(v_start_date, v_end_date, v_period_str, p_trace_id_input);

      SELECT JSON_ARRAYAGG(
               JSON_QUERY(v.val, '$' RETURNING CLOB)
               RETURNING CLOB
             ) AS result_json
      INTO v_json_output
      FROM (SELECT val
            FROM (JSON_TABLE(COALESCE(v_json_chapter_1_1, TO_CLOB(JSON_ARRAY())), '$[*]'
                             COLUMNS (val CLOB FORMAT JSON PATH '$')))
            WHERE val IS NOT NULL
            UNION ALL
            SELECT val
            FROM (JSON_TABLE(COALESCE(v_json_chapter_1_2, TO_CLOB(JSON_ARRAY())), '$[*]'
                             COLUMNS (val CLOB FORMAT JSON PATH '$')))
            WHERE val IS NOT NULL
            UNION ALL
            SELECT val
            FROM (JSON_TABLE(COALESCE(v_json_chapter_2_1, TO_CLOB(JSON_ARRAY())), '$[*]'
                             COLUMNS (val CLOB FORMAT JSON PATH '$')))
            WHERE val IS NOT NULL) v;
      it_log.log('traceId=''' || p_trace_id_input || ''' ' ||
                 'Построение отчёта успешно завершено: Расшифровка отчетной формы 0409706',
                 it_log.C_MSG_TYPE__DEBUG);
      RETURN v_json_output;

  EXCEPTION
      WHEN OTHERS THEN
          -- Если массив ошибок пустой, но мы всё равно сюда попали, значит произошло что-то непредвиденное
          it_error.put_error_in_stack;
          IF (v_errors_array.get_size() = 0) THEN
              v_errors_array.append(IT_CHECKLIMITREPORT.GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                                          C_ERR_99_MSG || ':' || SQLCODE || ' ' ||
                                                                          SQLERRM));
          END IF;

          RETURN IT_CHECKLIMITREPORT.BuildJsonOutput(p_errors_array => v_errors_array);

  END DECRYPT706_RC_REPORTRUN;

  ----- CHAPTER_1_1
  FUNCTION GENERATE_DECRYPT_706_REPORT_CHAPTER_1_1(v_start_date DATE, v_end_date DATE, v_period_str VARCHAR2,
                                                   p_trace_id_input VARCHAR2) RETURN CLOB IS
      C_TEMPLATE_NAME CONSTANT    VARCHAR2(128) := '0409706_ch1_1_decryption';
      C_OUTPUT_FILE_NAME CONSTANT VARCHAR2(128) := 'Расшифровка_0409706_раздел_1_подраздел_1';
      C_S3_FILE_NAME CONSTANT     VARCHAR2(128) := '0409706_ch1_1_decryption';
      C_REPORT_NAME_TAG CONSTANT  VARCHAR2(128) := 'chapter_1_1';
      C_ITEMS_ARR_TAG CONSTANT    VARCHAR2(128) := 'dataset';
      v_json_output               CLOB;
  BEGIN
      WITH chapter_1_1_data AS (SELECT tick.T_DEALID AS T_DEALID,
                                       avrName.name AS T_AVRNAME,
                                       fininstr.T_FIID AS T_FIID,
                                       tick.T_DEALCODE AS T_DEALCODE,
                                       tick.T_DEALDATE AS T_DEALDATE,
                                       leg.T_MATURITY AS T_CLIRINGDATE,
                                       COALESCE(ekk.T_EKK, '-1') AS T_CLIENTID,
                                       CASE WHEN tick.T_CLIENTID <> -1 THEN 'CLIENT' ELSE 'OWN' END AS T_TYPEDEAL,
                                       IT_CHECKLIMITREPORT.CONVERT_SUM_TO_RUB_BY_DATE_PROXY(tick.T_DEALDATE,
                                                                                            total_cost.cost,
                                                                                            cfi.cfi_Value) AS T_SUMMA,
                                       RSB_SECUR.GETDEALBUYSALE(tick.T_DEALTYPE, tick.T_BOFFICEKIND,
                                                                isBackTick.isBack) AS T_BUYSALE,
                                       party.T_NOTRESIDENT AS T_NOTRESIDENT,
                                       fininstr.T_FI_KIND AS T_FI_KIND,
                                       issuerName.name AS T_ISSUERNAME,
                                       FININSTR_ROOT.T_AVOIRKIND AS T_AVRTYPE,
                                       -1 AS T_ISSUERID
                                FROM ddl_tick_dbt tick
                                         LEFT JOIN (SELECT c.t_code AS t_ekk, m.t_sfcontrid
                                                    FROM ddlcontrmp_dbt m
                                                             JOIN ddlobjcode_dbt c
                                                                  ON c.t_objectid = m.t_dlcontrid
                                                                      AND c.t_objecttype = 207
                                                                      AND c.t_codekind = 1) ekk
                                                   ON tick.t_clientcontrid = ekk.t_sfcontrid
                                         JOIN ddl_leg_dbt leg ON (leg.t_DealID = tick.t_DealID)
                                         LEFT JOIN DFININSTR_DBT fininstr ON (leg.T_PFI = fininstr.T_FIID)
                                         LEFT JOIN (SELECT *
                                                    FROM (SELECT d.*,
                                                                 ROW_NUMBER() OVER (PARTITION BY d.T_DEALID ORDER BY d.T_OLDCHANGEDATE DESC) rn
                                                          FROM DSPTKCHNG_DBT d)
                                                    WHERE rn = 1) dspdd ON (dspdd.T_DEALID = tick.T_DEALID)
                                         LEFT JOIN (SELECT *
                                                    FROM (SELECT isshist.*,
                                                                 ROW_NUMBER() OVER (PARTITION BY isshist.T_FIID ORDER BY isshist.T_SORT ASC, isshist.T_ENDDATE ASC) rn
                                                          FROM DV_FI_ISSUER_HIST isshist
                                                          WHERE ((isshist.T_ENDDATE >= v_end_date OR
                                                                  isshist.T_ENDDATE =
                                                                  TO_DATE('01.01.0001', 'DD.MM.YYYY')) AND
                                                                 isshist.T_BEGDATE <= v_end_date))
                                                    WHERE (rn = 1)) history ON (history.T_FIID = leg.T_PFI)
                                         LEFT JOIN dparty_dbt party
                                                   ON (party.T_PARTYID = COALESCE(history.T_ISSUER, fininstr.T_ISSUER))
                                         JOIN (SELECT avrP.T_NAME, avrP.T_AVOIRKIND, avrC.T_FI_KIND AS FI_KIND,
                                                      avrC.T_AVOIRKIND AS AVOIRKIND,
                                                      avrC.T_NAME AS CHILD_NAME
                                               FROM DAVRKINDS_DBT avrC
                                                        JOIN DAVRKINDS_DBT avrP
                                                             ON (avrC.T_ROOT = avrP.T_AVOIRKIND AND avrC.T_FI_KIND = avrP.T_FI_KIND)) FININSTR_ROOT
                                              ON (FININSTR_ROOT.FI_KIND = fininstr.T_FI_KIND AND
                                                  FININSTR_ROOT.AVOIRKIND = fininstr.T_AVOIRKIND)
                                         LEFT JOIN DFININSTR_DBT parent_fininstr
                                                   ON (parent_fininstr.T_FIID = fininstr.T_PARENTFI AND
                                                       parent_fininstr.T_FI_KIND = fininstr.T_FI_KIND)
                                         LEFT JOIN DAVRKINDS_DBT parent_avoirkinds
                                                   ON (parent_fininstr.T_AVOIRKIND = parent_avoirkinds.T_AVOIRKIND AND
                                                       parent_fininstr.T_FI_KIND = parent_avoirkinds.T_FI_KIND)
                                         LEFT JOIN DPARTY_DBT demi ON (parent_fininstr.T_ISSUER = demi.T_PARTYID)
                                         CROSS APPLY (SELECT RSB_SECUR.GetObjAttrName(12, 28,
                                                                                      RSB_SECUR.GetMainObjAttr(12,
                                                                                                               TO_CHAR(fininstr.T_FIID, 'FM0000000000'),
                                                                                                               28,
                                                                                                               TO_DATE('31.12.9999', 'dd.MM.yyyy'))) AS name
                                                      FROM DUAL) objectattr
                                         CROSS APPLY (SELECT CASE
                                                                 WHEN (leg.T_RETURNINCOME <> 0 AND leg.T_LEGKIND = 2)
                                                                     THEN '1'
                                                                 ELSE '0'
                                                             END isBack
                                                      FROM DUAL) isBackTick
                                         CROSS APPLY (SELECT COALESCE(CASE
                                                                          WHEN (isBackTick.isBack = '1')
                                                                              THEN dspdd.T_OLDTOTALCOST2
                                                                          ELSE dspdd.T_OLDTOTALCOST1
                                                                      END, leg.T_TOTALCOST, 0) cost
                                                      FROM DUAL) total_cost
                                         CROSS APPLY (SELECT COALESCE(
                                                               CASE
                                                                   WHEN (isBackTick.isBack = '1') THEN dspdd.T_OLDCFI2
                                                                   ELSE dspdd.T_OLDCFI1
                                                               END,
                                                               leg.T_CFI, 0) cfi_Value
                                                      FROM DUAL) cfi
                                         CROSS APPLY (SELECT CASE
                                                                 WHEN
                                                                     rsb_secur.IsBasket(rsb_secur.get_OperationGroup(rsb_secur.get_OperSysTypes(tick.t_DealType, tick.t_BofficeKind))) =
                                                                     0 THEN (CASE
                                                                                 WHEN FININSTR_ROOT.T_AVOIRKIND = 16
                                                                                     THEN party.T_NAME
                                                                                 ELSE FININSTR_ROOT.CHILD_NAME
                                                                             END)
                                                                 ELSE NULL
                                                             END name
                                                      FROM DUAL) avrName
                                         CROSS APPLY (SELECT CASE
                                                                 WHEN FININSTR_ROOT.T_AVOIRKIND = 10 THEN (
                                                                     party.T_SHORTNAME || ' на ' ||
                                                                     parent_avoirkinds.T_NAME || ' ' ||
                                                                     demi.T_SHORTNAME)
                                                                 WHEN FININSTR_ROOT.T_AVOIRKIND = 16
                                                                                                     THEN (fininstr.T_NAME)
                                                                 ELSE party.T_NAME
                                                             END AS name
                                                      FROM DUAL) issuerName
                                WHERE (tick.t_BofficeKind = 101 OR tick.t_BofficeKind = 155)
                                  AND tick.t_DealStatus >= 10 AND leg.t_LegKind = 0 AND leg.t_LegID = 0
                                  AND tick.T_DEALTYPE != 32732 AND tick.T_DEALTYPE != 32742
                                  AND (leg.t_RejectDate > v_end_date OR
                                       leg.t_RejectDate = TO_DATE('01.01.0001', 'DD.MM.YYYY'))
                                  AND tick.t_DealDate BETWEEN v_start_date
                                    AND v_end_date
                                  AND tick.t_RequestID = 0 AND NOT EXISTS (SELECT 1
                                                                           FROM ddvndeal_dbt dvdeal
                                                                           WHERE dvdeal.t_ID = tick.t_ParentID AND tick.t_OriginID = 158)
                                  AND rsb_secur.IsOutExchange(
                                        rsb_secur.get_OperationGroup(rsb_secur.get_OperSysTypes(tick.t_DealType, tick.t_BofficeKind)),
                                        1) = 1
                                  AND (
                                    rsb_secur.IsRepo(rsb_secur.get_OperationGroup(rsb_secur.get_OperSysTypes(tick.t_DealType, tick.t_BofficeKind))) !=
                                    1
                                        OR
                                    (rsb_secur.IsRepo(rsb_secur.get_OperationGroup(rsb_secur.get_OperSysTypes(tick.t_DealType, tick.t_BofficeKind))) =
                                     1
                                        AND
                                     rsb_secur.IsBasket(rsb_secur.get_OperationGroup(rsb_secur.get_OperSysTypes(tick.t_DealType, tick.t_BofficeKind))) !=
                                     1
                                        AND NVL((SELECT leg2.t_RejectDate
                                                 FROM ddl_leg_dbt leg2
                                                 WHERE leg2.t_DealID = tick.t_DealID
                                                   AND leg2.t_LegKind = 2 AND leg2.t_LegID = 0
                                                   AND leg2.t_RejectDate != TO_DATE('01.01.0001', 'DD.MM.YYYY')),
                                                TO_DATE('01.01.9999', 'DD.MM.YYYY')) <
                                            v_end_date)
                                    )
                                  AND (party.T_NOTRESIDENT <> CHR(88) OR (objectattr.name <> 'Нет'))
                                  AND (FININSTR_ROOT.T_AVOIRKIND = 17 OR FININSTR_ROOT.T_AVOIRKIND = 20 OR
                                       FININSTR_ROOT.T_AVOIRKIND = 16 OR
                                       (FININSTR_ROOT.T_AVOIRKIND = 10 AND fininstr.T_AVOIRKIND = 47)
                                    OR (party.T_NOTRESIDENT = CHR(88) AND
                                        (fininstr.T_AVOIRKIND = 45 OR fininstr.T_AVOIRKIND = 49 OR
                                         fininstr.T_AVOIRKIND = 46)))
                                -------
                                UNION ALL
                                ---------
                                SELECT DVDeal.T_ID AS T_DEALID,
                                       FININSTR_ROOT.CHILD_NAME AS T_AVRNAME,
                                       baseFi.T_FIID AS T_FIID,
                                       DVDeal.T_CODE AS T_DEALCODE,
                                       DVDeal.T_DATE AS T_DEALDATE,
                                       nfi.T_PAYDATE AS T_CLIRINGDATE,
                                       COALESCE(ekk.T_EKK, '-1') AS T_CLIENTID,
                                       typeDealReq.isClientTypeDeal AS T_TYPEDEAL,
                                       IT_CHECKLIMITREPORT.CONVERT_SUM_TO_RUB_BY_DATE_PROXY(DVDeal.T_DATE,
                                                                                            dpmpaym.T_ORDERAMOUNT,
                                                                                            dpmpaym.T_ORDERFIID) AS T_SUMMA,
                                       buySale.buySale AS T_BUYSALE,
                                       party.T_NOTRESIDENT AS T_NOTRESIDENT,
                                       baseFi.T_FI_KIND AS T_FI_KIND,
                                       issuerName.name AS T_ISSUERNAME,
                                       FININSTR_ROOT.T_AVOIRKIND AS T_AVRTYPE,
                                       -1 AS T_ISSUERID
                                FROM ddvndeal_dbt DVDeal
                                         LEFT JOIN (SELECT c.t_code AS t_ekk, m.t_sfcontrid
                                                    FROM ddlcontrmp_dbt m
                                                             JOIN ddlobjcode_dbt c
                                                                  ON c.t_objectid = m.t_dlcontrid
                                                                      AND c.t_objecttype = 207
                                                                      AND c.t_codekind = 1) ekk
                                                   ON DVDeal.T_CLIENTCONTR = ekk.t_sfcontrid
                                         LEFT JOIN ddvnfi_dbt nfi
                                                   ON (((DVDeal.T_FORVARD = CHR(88)) AND
                                                        (nfi.t_dealid = DVDeal.T_ID) AND
                                                        (nfi.t_type = 1)) OR ((DVDeal.T_FORVARD <> CHR(88)) AND
                                                                              (nfi.t_dealid = DVDeal.T_ID) AND
                                                                              (nfi.t_type = 0)))
                                         LEFT JOIN DFININSTR_DBT baseFi
                                                   ON (((DVDeal.T_FORVARD = CHR(88)) AND (nfi.T_FIID = baseFi.T_FIID)) OR
                                                       ((DVDeal.T_FORVARD <> CHR(88)) AND (nfi.T_FIID = baseFi.T_FIID)))
                                         LEFT JOIN (SELECT *
                                                    FROM (SELECT isshist.*,
                                                                 ROW_NUMBER() OVER (PARTITION BY isshist.T_FIID ORDER BY isshist.T_SORT ASC, isshist.T_ENDDATE ASC) rn
                                                          FROM DV_FI_ISSUER_HIST isshist
                                                          WHERE ((isshist.T_ENDDATE >= v_end_date OR
                                                                  isshist.T_ENDDATE =
                                                                  TO_DATE('01.01.0001', 'DD.MM.YYYY')) AND
                                                                 isshist.T_BEGDATE <= v_end_date))
                                                    WHERE (rn = 1)) history
                                                   ON (history.T_FIID = baseFi.T_FIID)
                                         LEFT JOIN dparty_dbt party
                                                   ON (party.T_PARTYID = COALESCE(history.T_ISSUER, baseFi.T_ISSUER))
                                         LEFT JOIN davoiriss_dbt avoirss
                                                   ON (avoirss.T_FIID = baseFi.T_FIID) -- И зачем он мне ?
                                         LEFT JOIN davrserv_dbt avrserv
                                                   ON (avrserv.T_FIID = baseFi.T_FIID) -- И зачем он мне x2 ?
                                         LEFT JOIN (SELECT avrP.T_NAME, avrP.T_AVOIRKIND, avrC.T_FI_KIND AS FI_KIND,
                                                           avrC.T_AVOIRKIND AS AVOIRKIND, avrC.T_NAME AS CHILD_NAME
                                                    FROM DAVRKINDS_DBT avrC
                                                             JOIN DAVRKINDS_DBT avrP
                                                                  ON (avrC.T_ROOT = avrP.T_AVOIRKIND AND avrC.T_FI_KIND = avrP.T_FI_KIND)) FININSTR_ROOT
                                                   ON (FININSTR_ROOT.FI_KIND = baseFi.T_FI_KIND AND
                                                       FININSTR_ROOT.AVOIRKIND = baseFi.T_AVOIRKIND)
                                         LEFT JOIN dpmpaym_dbt dpmpaym
                                                   ON ((dpmpaym.t_dockind = DVDeal.T_DOCKIND) AND
                                                       (dpmpaym.t_documentid = DVDeal.T_ID) AND
                                                       (dpmpaym.t_purpose = 2) AND (dpmpaym.t_subpurpose = 0))
                                         LEFT JOIN DFININSTR_DBT parent_fininstr
                                                   ON (parent_fininstr.T_FIID = baseFi.T_PARENTFI AND
                                                       parent_fininstr.T_FI_KIND = baseFi.T_FI_KIND)
                                         LEFT JOIN (SELECT *
                                                    FROM (SELECT isshist.*,
                                                                 ROW_NUMBER() OVER (PARTITION BY isshist.T_FIID ORDER BY isshist.T_SORT ASC, isshist.T_ENDDATE ASC) rn
                                                          FROM DV_FI_ISSUER_HIST isshist
                                                          WHERE ((isshist.T_ENDDATE >= v_end_date OR
                                                                  isshist.T_ENDDATE =
                                                                  TO_DATE('01.01.0001', 'DD.MM.YYYY')) AND
                                                                 isshist.T_BEGDATE <= v_end_date))
                                                    WHERE (rn = 1)) history_root
                                                   ON (history.T_FIID = parent_fininstr.T_FIID)
                                         LEFT JOIN dparty_dbt party_root
                                                   ON (party.T_PARTYID =
                                                       COALESCE(history_root.T_ISSUER, parent_fininstr.T_ISSUER))
                                         LEFT JOIN DPARTY_DBT demi ON (parent_fininstr.T_ISSUER = demi.T_PARTYID)
                                         LEFT JOIN DAVRKINDS_DBT parent_avoirkinds
                                                   ON (parent_fininstr.T_AVOIRKIND = parent_avoirkinds.T_AVOIRKIND AND
                                                       parent_fininstr.T_FI_KIND = parent_avoirkinds.T_FI_KIND)
                                         CROSS APPLY (SELECT RSB_SECUR.GetObjAttrName(12, 28,
                                                                                      RSB_SECUR.GetMainObjAttr(12,
                                                                                                               TO_CHAR(baseFi.T_FIID, 'FM0000000000'),
                                                                                                               28,
                                                                                                               TO_DATE('31.12.9999', 'dd.MM.yyyy'))) AS name
                                                      FROM DUAL) objectattr
                                         CROSS APPLY (SELECT CASE WHEN DVDeal.T_CLIENT > 0 THEN 'CLIENT' ELSE 'OWN' END AS isClientTypeDeal
                                                      FROM DUAL) typeDealReq
                                         CROSS APPLY (SELECT CASE WHEN (DVDeal.T_TYPE = 1 OR DVDeal.T_TYPE = 5) THEN 2 ELSE 1 END AS buySale
                                                      FROM DUAL) buySale
                                         CROSS APPLY (SELECT CASE
                                                                 WHEN FININSTR_ROOT.T_AVOIRKIND = 10 THEN (
                                                                     party.T_SHORTNAME || ' на ' ||
                                                                     parent_avoirkinds.T_NAME || ' ' ||
                                                                     demi.T_SHORTNAME)
                                                                 ELSE party.T_NAME
                                                             END AS name
                                                      FROM DUAL) issuerName
                                WHERE nfi.T_TYPE = 0
                                  AND baseFi.t_FI_KIND = 2
                                  AND DVDeal.T_IsTrust = CHR(0)
                                  AND DVDeal.T_DVKIND IN (1, 5, 2)
                                  AND DVDeal.T_State > 0
                                  AND DVDeal.T_Date >= v_start_date
                                  AND DVDeal.T_Date <= v_end_date
                                  AND nFI.t_ExecType = 1
                                  AND NOT EXISTS (SELECT 1
                                                  FROM DPARTYOWN_DBT PARTYOWN
                                                  WHERE PARTYOWN.T_PARTYID = DVDeal.T_Contractor
                                                    AND PARTYOWN.T_PARTYKIND = 3)
                                  AND (FININSTR_ROOT.T_AVOIRKIND IN (20, 17, 16) OR
                                       (FININSTR_ROOT.T_AVOIRKIND = 10 AND baseFi.T_AVOIRKIND = 47))
                                  AND (party.T_NOTRESIDENT <> CHR(88) OR (objectattr.name <> 'Нет'))
                                  AND (FININSTR_ROOT.T_AVOIRKIND = 17 OR FININSTR_ROOT.T_AVOIRKIND = 20 OR
                                       FININSTR_ROOT.T_AVOIRKIND = 16 OR
                                       (FININSTR_ROOT.T_AVOIRKIND = 10 AND baseFi.T_AVOIRKIND = 47))
                                UNION ALL
                                SELECT tk.T_DEALID AS T_DEALID,
                                       avoir.T_NAME AS T_AVRNAME,
                                       bnr.t_FIID AS T_FIID,
                                       tk.T_DEALCODE AS T_DEALCODE,
                                       tk.T_DEALDATE AS T_DEALDATE,
                                       leg.T_MATURITY AS T_CLIRINGDATE,
                                       COALESCE(ekk.T_EKK, '-1') AS T_CLIENTID,
                                       typeDealReq.isClientTypeDeal AS T_TYPEDEAL,
                                       IT_CHECKLIMITREPORT.CONVERT_SUM_TO_RUB_BY_DATE_PROXY(tk.t_DealDate, lnk.t_BCCost,
                                                                                            lnk.t_BCCFI) AS T_SUMMA,
                                       CASE WHEN (lnk.t_LinkKind = 1) THEN 2 ELSE 1 END AS T_BUYSALE,
                                       iss.t_NotResident AS T_NOTRESIDENT,
                                       2 AS T_FI_KIND,
                                       iss.t_Name AS T_ISSUERNAME,
                                       fi.t_AvoirKind AS T_AVRTYPE,
                                       bnr.t_Issuer AS T_ISSUERID
                                FROM ddl_tick_dbt tk
                                         LEFT JOIN (SELECT c.t_code AS t_ekk, m.t_sfcontrid
                                                    FROM ddlcontrmp_dbt m
                                                             JOIN ddlobjcode_dbt c
                                                                  ON c.t_objectid = m.t_dlcontrid
                                                                      AND c.t_objecttype = 207
                                                                      AND c.t_codekind = 1) ekk
                                                   ON tk.T_CLIENTCONTRID = ekk.t_sfcontrid
                                         JOIN ddl_leg_dbt leg ON (leg.t_DealID = tk.t_DealID)
                                         LEFT JOIN dvsordlnk_dbt lnk
                                                   ON (lnk.t_ContractID = tk.t_DealID AND lnk.t_DocKind = tk.t_BOfficeKind)
                                         LEFT JOIN dvsbanner_dbt bnr ON (bnr.t_BCID = lnk.t_BCID)
                                         LEFT JOIN dparty_dbt iss ON (iss.t_PartyID = bnr.t_Issuer)
                                         LEFT JOIN dfininstr_dbt fi ON (fi.t_FIID = bnr.t_FIID)
                                         LEFT JOIN DAVRKINDS_DBT avoir
                                                   ON (avoir.T_AVOIRKIND = fi.t_AvoirKind AND avoir.T_FI_KIND = fi.T_FI_KIND)
                                         CROSS APPLY (SELECT CASE WHEN tk.t_ClientID > 0 THEN 'CLIENT' ELSE 'OWN' END AS isClientTypeDeal
                                                      FROM DUAL) typeDealReq
                                         CROSS APPLY (SELECT RSB_SECUR.GetObjAttrName(12, 28,
                                                                                      RSB_SECUR.GetMainObjAttr(12,
                                                                                                               TO_CHAR(fi.T_FIID, 'FM0000000000'),
                                                                                                               28,
                                                                                                               TO_DATE('31.12.9999', 'dd.MM.yyyy'))) AS name
                                                      FROM DUAL) objectattr
                                WHERE (tk.t_BOfficeKind = 141 OR tk.t_BOfficeKind = 143)
                                  AND tk.t_DealStatus >= 10
                                  AND tk.t_DealDate >= v_start_date
                                  AND tk.t_DealDate <= v_end_date
                                  AND (fi.t_AvoirKind = 5 OR fi.t_AvoirKind = 9)
                                  AND bnr.t_Issuer NOT IN (SELECT d.t_PartyID FROM ddp_dep_dbt d)
                                  AND (iss.T_NOTRESIDENT <> CHR(88) OR (objectattr.name <> 'Нет'))),
           chapert_1        AS (SELECT (t.t_AvrName || ' ' || t.t_ISSUERNAME) AS SecNAme, av.t_LSIN AS gos_num,
                                       av.t_ISIN AS ISIN, t.T_DEALCODE AS dealNum,
                                       t.T_DEALDATE AS dealDate, t.T_CLIRINGDATE AS clrDate, t.T_CLIENTID AS client,
                                       CASE
                                           WHEN (t.t_TypeDeal = 'OWN' AND t.T_BUYSALE = 2) THEN t.T_SUMMA
                                           ELSE 0
                                       END AS ownB,
                                       CASE
                                           WHEN (t.t_TypeDeal = 'OWN' AND t.T_BUYSALE = 1) THEN t.T_SUMMA
                                           ELSE 0
                                       END AS ownS,
                                       CASE
                                           WHEN (t.t_TypeDeal = 'CLIENT' AND t.T_BUYSALE = 2) THEN t.T_SUMMA
                                           ELSE 0
                                       END AS clientB,
                                       CASE
                                           WHEN (t.t_TypeDeal = 'CLIENT' AND t.T_BUYSALE = 1) THEN t.T_SUMMA
                                           ELSE 0
                                       END AS clientS,
                                       t.T_FIID, t.T_NOTRESIDENT, t.T_AVRTYPE,
                                       CASE (t.T_AVRTYPE)
                                           WHEN (20) THEN 1
                                           WHEN (17) THEN 2
                                           WHEN (16) THEN 3
                                           WHEN (5)  THEN 4
                                           WHEN (9)  THEN 5
                                           WHEN (10) THEN 6
                                           ELSE 100 + t.T_AVRTYPE
                                       END AS T_ORDER
                                FROM chapter_1_1_data t, davoiriss_dbt av
                                WHERE t.t_FI_Kind = 2
                                  AND av.t_fiid = t.t_fiid),
           req_result       AS (SELECT r.lvl1 || '.' || r.lvl2 || '.' || r.lvl3 AS num_code, r.*
                                FROM (SELECT ch.*,
                                             DENSE_RANK() OVER (
                                                 ORDER BY ch.T_NOTRESIDENT
                                                 ) AS lvl1,

                                             DENSE_RANK() OVER (
                                                 PARTITION BY ch.T_NOTRESIDENT
                                                 ORDER BY ch.T_ORDER
                                                 ) AS lvl2,

                                             DENSE_RANK() OVER (
                                                 PARTITION BY ch.T_NOTRESIDENT, ch.T_ORDER
                                                 ORDER BY ch.SecNAme, ch.gos_num, ch.ISIN
                                                 ) AS lvl3
                                      FROM chapert_1 ch) r
                                ORDER BY r.lvl1, r.lvl2, r.lvl3)
      SELECT (
                 JSON_ARRAYAGG(
                   JSON_OBJECT(
                     'counter' VALUE num_code,
                     'SecNAme' VALUE SecNAme,
                     'gos_num' VALUE gos_num,
                     'ISIN' VALUE ISIN,
                     'dealNum' VALUE dealNum,
                     'dealDate' VALUE dealDate,
                     'clrDate' VALUE clrDate,
                     'client' VALUE client,
                     'ownB' VALUE ownB,
                     'ownS' VALUE ownS,
                     'clientB' VALUE clientB,
                     'clientS' VALUE clientS,
                     'founderB' VALUE 0,
                     'founderS' VALUE 0
                   ) RETURNING CLOB
                 )
                 )
      INTO v_json_output
      FROM (SELECT r.*
            FROM req_result r
            UNION ALL
            -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
            SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                   NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
            FROM dual
            WHERE NOT EXISTS (SELECT 1 FROM req_result));

      v_json_output := BuildSplitJsonOutputWithAdditionalParams(p_trace_id_input => p_trace_id_input,
                                                                p_json_input => v_json_output,
                                                                p_json_addfileds => JSON_ARRAY(JSON_OBJECT('key' VALUE
                                                                                                           'period',
                                                                                                           'value' VALUE
                                                                                                           v_period_str,
                                                                                                           'type' VALUE
                                                                                                           'VARCHAR')),
                                                                p_report_date_input => v_start_date,
                                                                p_report_tag => C_REPORT_NAME_TAG,
                                                                p_items_arr_tag => C_ITEMS_ARR_TAG,
                                                                p_template_name => C_TEMPLATE_NAME,
                                                                p_output_file_name => C_OUTPUT_FILE_NAME,
                                                                p_s3_file_name => C_S3_FILE_NAME);
      RETURN v_json_output;
  END GENERATE_DECRYPT_706_REPORT_CHAPTER_1_1;

  ----- CHAPTER_1_2
  FUNCTION GENERATE_DECRYPT_706_REPORT_CHAPTER_1_2(v_start_date DATE, v_end_date DATE, v_period_str VARCHAR2,
                                                   p_trace_id_input VARCHAR2) RETURN CLOB IS
      C_TEMPLATE_NAME CONSTANT    VARCHAR2(128) := '0409706_ch1_2_decryption';
      C_OUTPUT_FILE_NAME CONSTANT VARCHAR2(128) := 'Расшифровка_0409706_раздел_1_подраздел_2';
      C_S3_FILE_NAME CONSTANT     VARCHAR2(128) := '0409706_ch1_2_decryption';
      C_REPORT_NAME_TAG CONSTANT  VARCHAR2(128) := 'chapter_1_2';
      C_ITEMS_ARR_TAG CONSTANT    VARCHAR2(128) := 'dataset';
      v_json_output               CLOB;
  BEGIN
      WITH chapter_1_2_data AS (SELECT tick.T_DEALID AS T_DEALID,
                                       avrName.name AS T_AVRNAME,
                                       fininstr.T_FIID AS T_FIID,
                                       tick.T_DEALCODE AS T_DEALCODE,
                                       tick.T_DEALDATE AS T_DEALDATE,
                                       leg.T_MATURITY AS T_CLIRINGDATE,
                                       COALESCE(ekk.T_EKK, '-1') AS T_CLIENTID,
                                       CASE WHEN tick.T_CLIENTID <> -1 THEN 'CLIENT' ELSE 'OWN' END AS T_TYPEDEAL,
                                       IT_CHECKLIMITREPORT.CONVERT_SUM_TO_RUB_BY_DATE_PROXY(tick.T_DEALDATE,
                                                                                            total_cost.cost,
                                                                                            cfi.cfi_Value) AS T_SUMMA,
                                       RSB_SECUR.GETDEALBUYSALE(tick.T_DEALTYPE, tick.T_BOFFICEKIND,
                                                                isBackTick.isBack) AS T_BUYSALE,
                                       party.T_NOTRESIDENT AS T_NOTRESIDENT,
                                       fininstr.T_FI_KIND AS T_FI_KIND,
                                       issuerName.name AS T_ISSUERNAME,
                                       FININSTR_ROOT.T_AVOIRKIND AS T_AVRTYPE,
                                       -1 AS T_ISSUERID
                                FROM ddl_tick_dbt tick
                                         LEFT JOIN (SELECT c.t_code AS t_ekk, m.t_sfcontrid
                                                    FROM ddlcontrmp_dbt m
                                                             JOIN ddlobjcode_dbt c
                                                                  ON c.t_objectid = m.t_dlcontrid
                                                                      AND c.t_objecttype = 207
                                                                      AND c.t_codekind = 1) ekk
                                                   ON tick.T_CLIENTCONTRID = ekk.t_sfcontrid
                                         JOIN ddl_leg_dbt leg ON (leg.t_DealID = tick.t_DealID)
                                         LEFT JOIN DFININSTR_DBT fininstr ON (leg.T_PFI = fininstr.T_FIID)
                                         LEFT JOIN (SELECT *
                                                    FROM (SELECT d.*,
                                                                 ROW_NUMBER() OVER (PARTITION BY d.T_DEALID ORDER BY d.T_OLDCHANGEDATE DESC) rn
                                                          FROM DSPTKCHNG_DBT d)
                                                    WHERE rn = 1) dspdd ON (dspdd.T_DEALID = tick.T_DEALID)
                                         LEFT JOIN (SELECT *
                                                    FROM (SELECT isshist.*,
                                                                 ROW_NUMBER() OVER (PARTITION BY isshist.T_FIID ORDER BY isshist.T_SORT ASC, isshist.T_ENDDATE ASC) rn
                                                          FROM DV_FI_ISSUER_HIST isshist
                                                          WHERE ((isshist.T_ENDDATE >= v_end_date OR
                                                                  isshist.T_ENDDATE =
                                                                  TO_DATE('01.01.0001', 'DD.MM.YYYY')) AND
                                                                 isshist.T_BEGDATE <= v_end_date))
                                                    WHERE (rn = 1)) history ON (history.T_FIID = leg.T_PFI)
                                         LEFT JOIN dparty_dbt party
                                                   ON (party.T_PARTYID = COALESCE(history.T_ISSUER, fininstr.T_ISSUER))
                                         JOIN (SELECT avrP.T_NAME, avrP.T_AVOIRKIND, avrC.T_FI_KIND AS FI_KIND,
                                                      avrC.T_AVOIRKIND AS AVOIRKIND,
                                                      avrC.T_NAME AS CHILD_NAME
                                               FROM DAVRKINDS_DBT avrC
                                                        JOIN DAVRKINDS_DBT avrP
                                                             ON (avrC.T_ROOT = avrP.T_AVOIRKIND AND avrC.T_FI_KIND = avrP.T_FI_KIND)) FININSTR_ROOT
                                              ON (FININSTR_ROOT.FI_KIND = fininstr.T_FI_KIND AND
                                                  FININSTR_ROOT.AVOIRKIND = fininstr.T_AVOIRKIND)
                                         LEFT JOIN DFININSTR_DBT parent_fininstr
                                                   ON (parent_fininstr.T_FIID = fininstr.T_PARENTFI AND
                                                       parent_fininstr.T_FI_KIND = fininstr.T_FI_KIND)
                                         LEFT JOIN DAVRKINDS_DBT parent_avoirkinds
                                                   ON (parent_fininstr.T_AVOIRKIND = parent_avoirkinds.T_AVOIRKIND AND
                                                       parent_fininstr.T_FI_KIND = parent_avoirkinds.T_FI_KIND)
                                         LEFT JOIN DPARTY_DBT demi ON (parent_fininstr.T_ISSUER = demi.T_PARTYID)
                                         CROSS APPLY (SELECT RSB_SECUR.GetObjAttrName(12, 28,
                                                                                      RSB_SECUR.GetMainObjAttr(12,
                                                                                                               TO_CHAR(fininstr.T_FIID, 'FM0000000000'),
                                                                                                               28,
                                                                                                               TO_DATE('31.12.9999', 'dd.MM.yyyy'))) AS name
                                                      FROM DUAL) objectattr
                                         CROSS APPLY (SELECT CASE
                                                                 WHEN (leg.T_RETURNINCOME <> 0 AND leg.T_LEGKIND = 2)
                                                                     THEN '1'
                                                                 ELSE '0'
                                                             END isBack
                                                      FROM DUAL) isBackTick
                                         CROSS APPLY (SELECT COALESCE(CASE
                                                                          WHEN (isBackTick.isBack = '1')
                                                                              THEN dspdd.T_OLDTOTALCOST2
                                                                          ELSE dspdd.T_OLDTOTALCOST1
                                                                      END, leg.T_TOTALCOST, 0) cost
                                                      FROM DUAL) total_cost
                                         CROSS APPLY (SELECT COALESCE(
                                                               CASE
                                                                   WHEN (isBackTick.isBack = '1') THEN dspdd.T_OLDCFI2
                                                                   ELSE dspdd.T_OLDCFI1
                                                               END,
                                                               leg.T_CFI, 0) cfi_Value
                                                      FROM DUAL) cfi
                                         CROSS APPLY (SELECT CASE
                                                                 WHEN
                                                                     rsb_secur.IsBasket(rsb_secur.get_OperationGroup(rsb_secur.get_OperSysTypes(tick.t_DealType, tick.t_BofficeKind))) =
                                                                     0 THEN (CASE
                                                                                 WHEN FININSTR_ROOT.T_AVOIRKIND = 16
                                                                                     THEN party.T_NAME
                                                                                 ELSE FININSTR_ROOT.CHILD_NAME
                                                                             END)
                                                                 ELSE NULL
                                                             END name
                                                      FROM DUAL) avrName
                                         CROSS APPLY (SELECT CASE
                                                                 WHEN FININSTR_ROOT.T_AVOIRKIND = 10 THEN (
                                                                     party.T_SHORTNAME || ' на ' ||
                                                                     parent_avoirkinds.T_NAME || ' ' ||
                                                                     demi.T_SHORTNAME)
                                                                 WHEN FININSTR_ROOT.T_AVOIRKIND = 16
                                                                                                     THEN (fininstr.T_NAME)
                                                                 ELSE party.T_NAME
                                                             END AS name
                                                      FROM DUAL) issuerName
                                WHERE (tick.t_BofficeKind = 101 OR tick.t_BofficeKind = 155)
                                  AND tick.t_DealStatus >= 10 AND leg.t_LegKind = 0 AND leg.t_LegID = 0
                                  AND tick.T_DEALTYPE != 32732 AND tick.T_DEALTYPE != 32742
                                  AND (leg.t_RejectDate > v_start_date OR
                                       leg.t_RejectDate = TO_DATE('01.01.0001', 'DD.MM.YYYY'))
                                  AND tick.t_DealDate BETWEEN v_start_date
                                    AND v_end_date
                                  AND tick.t_RequestID = 0 AND NOT EXISTS (SELECT 1
                                                                           FROM ddvndeal_dbt dvdeal
                                                                           WHERE dvdeal.t_ID = tick.t_ParentID AND tick.t_OriginID = 158)
                                  AND
                                    rsb_secur.IsBroker(rsb_secur.get_OperationGroup(rsb_secur.get_OperSysTypes(tick.t_DealType, tick.t_BofficeKind))) =
                                    1
                                  AND tick.t_BrokerID <> -1
                                  AND EXISTS (SELECT 1
                                              FROM dpartyown_dbt partyown
                                              WHERE partyown.t_PartyKind = 22
                                                AND partyown.t_PartyID = tick.t_BrokerID)
                                  AND EXISTS (SELECT 1
                                              FROM dsfcontr_dbt sfcontr
                                              WHERE sfcontr.t_ServKind = 1
                                                AND sfcontr.t_PartyID = 1
                                                AND sfcontr.t_ContractorID = tick.t_BrokerID)
                                  AND tick.t_MarketID = -1
                                  AND (party.T_NOTRESIDENT <> CHR(88) OR (objectattr.name <> 'Нет'))
                                  AND (FININSTR_ROOT.T_AVOIRKIND = 17 OR FININSTR_ROOT.T_AVOIRKIND = 20 OR
                                       FININSTR_ROOT.T_AVOIRKIND = 16 OR
                                       (FININSTR_ROOT.T_AVOIRKIND = 10 AND fininstr.T_AVOIRKIND = 47)
                                    OR (party.T_NOTRESIDENT = CHR(88) AND
                                        (fininstr.T_AVOIRKIND = 45 OR fininstr.T_AVOIRKIND = 49 OR
                                         fininstr.T_AVOIRKIND = 46)))),
           chapert_1_2      AS (SELECT (t.t_AvrName || ' ' || t.t_ISSUERNAME) AS SecNAme, av.t_LSIN AS gos_num,
                                       av.t_ISIN AS ISIN, t.T_DEALCODE AS dealNum,
                                       t.T_DEALDATE AS dealDate, t.T_CLIRINGDATE AS clrDate, t.T_CLIENTID AS client,
                                       CASE
                                           WHEN (t.t_TypeDeal = 'OWN' AND t.T_BUYSALE = 2) THEN t.T_SUMMA
                                           ELSE 0
                                       END AS ownB,
                                       CASE
                                           WHEN (t.t_TypeDeal = 'OWN' AND t.T_BUYSALE = 1) THEN t.T_SUMMA
                                           ELSE 0
                                       END AS ownS,
                                       CASE
                                           WHEN (t.t_TypeDeal = 'CLIENT' AND t.T_BUYSALE = 2) THEN t.T_SUMMA
                                           ELSE 0
                                       END AS clientB,
                                       CASE
                                           WHEN (t.t_TypeDeal = 'CLIENT' AND t.T_BUYSALE = 1) THEN t.T_SUMMA
                                           ELSE 0
                                       END AS clientS,
                                       t.T_FIID, t.T_NOTRESIDENT, t.T_AVRTYPE,
                                       CASE (t.T_AVRTYPE)
                                           WHEN (20) THEN 1
                                           WHEN (17) THEN 2
                                           WHEN (16) THEN 3
                                           WHEN (5)  THEN 4
                                           WHEN (9)  THEN 5
                                           WHEN (10) THEN 6
                                           ELSE 100 + t.T_AVRTYPE
                                       END AS T_ORDER
                                FROM chapter_1_2_data t, davoiriss_dbt av
                                WHERE t.t_FI_Kind = 2
                                  AND av.t_fiid = t.t_fiid),
           req_result       AS (SELECT r.lvl1 || '.' || r.lvl2 || '.' || r.lvl3 AS num_code, r.*
                                FROM (SELECT ch.*,
                                             DENSE_RANK() OVER (
                                                 ORDER BY ch.T_NOTRESIDENT
                                                 ) AS lvl1,

                                             DENSE_RANK() OVER (
                                                 PARTITION BY ch.T_NOTRESIDENT
                                                 ORDER BY ch.T_ORDER
                                                 ) AS lvl2,

                                             DENSE_RANK() OVER (
                                                 PARTITION BY ch.T_NOTRESIDENT, ch.T_ORDER
                                                 ORDER BY ch.SecNAme, ch.gos_num, ch.ISIN
                                                 ) AS lvl3
                                      FROM chapert_1_2 ch) r
                                ORDER BY r.lvl1, r.lvl2, r.lvl3)
      SELECT (
                 JSON_ARRAYAGG(
                   JSON_OBJECT(
                     'counter' VALUE num_code,
                     'SecNAme' VALUE SecNAme,
                     'gos_num' VALUE gos_num,
                     'ISIN' VALUE ISIN,
                     'dealNum' VALUE dealNum,
                     'dealDate' VALUE dealDate,
                     'clrDate' VALUE clrDate,
                     'client' VALUE client,
                     'ownB' VALUE ownB,
                     'ownS' VALUE ownS,
                     'clientB' VALUE clientB,
                     'clientS' VALUE clientS,
                     'founderB' VALUE 0,
                     'founderS' VALUE 0
                   ) RETURNING CLOB
                 )
                 )
      INTO v_json_output
      FROM (SELECT r.*
            FROM req_result r
            UNION ALL
            -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
            SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                   NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
            FROM dual
            WHERE NOT EXISTS (SELECT 1 FROM req_result));

      v_json_output := BuildSplitJsonOutputWithAdditionalParams(p_trace_id_input => p_trace_id_input,
                                                                p_json_input => v_json_output,
                                                                p_json_addfileds => JSON_ARRAY(JSON_OBJECT('key' VALUE
                                                                                                           'period',
                                                                                                           'value' VALUE
                                                                                                           v_period_str,
                                                                                                           'type' VALUE
                                                                                                           'VARCHAR')),
                                                                p_report_date_input => v_start_date,
                                                                p_report_tag => C_REPORT_NAME_TAG,
                                                                p_items_arr_tag => C_ITEMS_ARR_TAG,
                                                                p_template_name => C_TEMPLATE_NAME,
                                                                p_output_file_name => C_OUTPUT_FILE_NAME,
                                                                p_s3_file_name => C_S3_FILE_NAME);
      RETURN v_json_output;
  END GENERATE_DECRYPT_706_REPORT_CHAPTER_1_2;

  ----- CHAPTER_2_1
  FUNCTION GENERATE_DECRYPT_706_REPORT_CHAPTER_2_1(v_start_date DATE, v_end_date DATE, v_period_str VARCHAR2,
                                                   p_trace_id_input VARCHAR2) RETURN CLOB IS
      C_TEMPLATE_NAME CONSTANT    VARCHAR2(128) := '0409706_ch2_decryption';
      C_OUTPUT_FILE_NAME CONSTANT VARCHAR2(128) := 'Расшифровка_0409706_раздел_2';
      C_S3_FILE_NAME CONSTANT     VARCHAR2(128) := '0409706_ch2_decryption';
      C_REPORT_NAME_TAG CONSTANT  VARCHAR2(128) := 'chapter_2';
      C_ITEMS_ARR_TAG CONSTANT    VARCHAR2(128) := 'dataset';
      v_json_output               CLOB;
  BEGIN
      WITH chapter_2_1_data AS (SELECT tick.T_DEALID AS T_DEALID,
                                       CASE
                                           WHEN (basket.isBasket = 1) THEN tick_ens.t_Name
                                           ELSE avrName.name
                                       END AS T_AVRNAME,
                                       CASE
                                           WHEN (basket.isBasket = 1) THEN tick_ens.T_FIID
                                           ELSE fininstr.T_FIID
                                       END AS T_FIID,
                                       tick.T_DEALCODE AS T_DEALCODE,
                                       tick.T_DEALDATE AS T_DEALDATE,
                                       leg.T_MATURITY AS T_CLIRINGDATE,
                                       COALESCE(ekk.T_EKK, '-1') AS T_CLIENTID,
                                       CASE WHEN tick.T_CLIENTID <> -1 THEN 'CLIENT' ELSE 'OWN' END AS T_TYPEDEAL,
                                       IT_CHECKLIMITREPORT.CONVERT_SUM_TO_RUB_BY_DATE_PROXY(tick.T_DEALDATE,
                                                                                            total_cost.cost,
                                                                                            cfi.cfi_Value) AS T_SUMMA,
                                       RSB_SECUR.GETDEALBUYSALE(tick.T_DEALTYPE, tick.T_BOFFICEKIND,
                                                                isBackTick.isBack) AS T_BUYSALE,
                                       party.T_NOTRESIDENT AS T_NOTRESIDENT,
                                       CASE
                                           WHEN (basket.isBasket = 1) THEN tick_ens.T_FI_KIND
                                           ELSE fininstr.T_FI_KIND
                                       END AS T_FI_KIND,
                                       CASE
                                           WHEN (basket.isBasket = 1) THEN issuerName_ens.name
                                           ELSE issuerName.name
                                       END AS T_ISSUERNAME,
                                       CASE
                                           WHEN (basket.isBasket = 1) THEN
                                               CASE
                                                   WHEN (tick_ens.childavoirs_root_avoirkind = 10 AND
                                                         (tick_ens.T_AVOIRKIND = 47 OR
                                                          (party.T_NOTRESIDENT = CHR(88) AND
                                                           (tick_ens.T_AVOIRKIND = 45 OR
                                                            tick_ens.T_AVOIRKIND = 49 OR
                                                            tick_ens.T_AVOIRKIND = 46))))          THEN 10
                                                   WHEN (tick_ens.childavoirs_root_avoirkind = 20) THEN 20
                                                   WHEN (tick_ens.childavoirs_root_avoirkind = 17) THEN 17
                                                   WHEN (tick_ens.childavoirs_root_avoirkind = 16) THEN 16
                                                   ELSE FININSTR_ROOT.T_AVOIRKIND
                                               END
                                           ELSE FININSTR_ROOT.T_AVOIRKIND
                                       END AS T_AVRTYPE,
                                       -1 AS T_ISSUERID
                                FROM ddl_tick_dbt tick
                                         LEFT JOIN (SELECT c.t_code AS t_ekk, m.t_sfcontrid
                                                    FROM ddlcontrmp_dbt m
                                                             JOIN ddlobjcode_dbt c
                                                                  ON c.t_objectid = m.t_dlcontrid
                                                                      AND c.t_objecttype = 207
                                                                      AND c.t_codekind = 1) ekk
                                                   ON tick.T_CLIENTCONTRID = ekk.t_sfcontrid
                                         JOIN ddl_leg_dbt leg ON (leg.t_DealID = tick.t_DealID)
                                         LEFT JOIN DFININSTR_DBT fininstr ON (leg.T_PFI = fininstr.T_FIID)
                                         LEFT JOIN (SELECT *
                                                    FROM (SELECT d.*,
                                                                 ROW_NUMBER() OVER (PARTITION BY d.T_DEALID ORDER BY d.T_OLDCHANGEDATE DESC) rn
                                                          FROM DSPTKCHNG_DBT d)
                                                    WHERE rn = 1) dspdd ON (dspdd.T_DEALID = tick.T_DEALID)
                                         LEFT JOIN (SELECT *
                                                    FROM (SELECT isshist.*,
                                                                 ROW_NUMBER() OVER (PARTITION BY isshist.T_FIID ORDER BY isshist.T_SORT ASC, isshist.T_ENDDATE ASC) rn
                                                          FROM DV_FI_ISSUER_HIST isshist
                                                          WHERE ((isshist.T_ENDDATE >= v_end_date OR
                                                                  isshist.T_ENDDATE =
                                                                  TO_DATE('01.01.0001', 'DD.MM.YYYY')) AND
                                                                 isshist.T_BEGDATE <= v_end_date))
                                                    WHERE (rn = 1)) history ON (history.T_FIID = leg.T_PFI)
                                         LEFT JOIN dparty_dbt party
                                                   ON (party.T_PARTYID = COALESCE(history.T_ISSUER, fininstr.T_ISSUER))
                                         JOIN (SELECT avrP.T_NAME, avrP.T_AVOIRKIND, avrC.T_FI_KIND AS FI_KIND,
                                                      avrC.T_AVOIRKIND AS AVOIRKIND,
                                                      avrC.T_NAME AS CHILD_NAME
                                               FROM DAVRKINDS_DBT avrC
                                                        JOIN DAVRKINDS_DBT avrP
                                                             ON (avrC.T_ROOT = avrP.T_AVOIRKIND AND avrC.T_FI_KIND = avrP.T_FI_KIND)) FININSTR_ROOT
                                              ON (FININSTR_ROOT.FI_KIND = fininstr.T_FI_KIND AND
                                                  FININSTR_ROOT.AVOIRKIND = fininstr.T_AVOIRKIND)
                                         LEFT JOIN DFININSTR_DBT parent_fininstr
                                                   ON (parent_fininstr.T_FIID = fininstr.T_PARENTFI AND
                                                       parent_fininstr.T_FI_KIND = fininstr.T_FI_KIND)
                                         LEFT JOIN DAVRKINDS_DBT parent_avoirkinds
                                                   ON (parent_fininstr.T_AVOIRKIND = parent_avoirkinds.T_AVOIRKIND AND
                                                       parent_fininstr.T_FI_KIND = parent_avoirkinds.T_FI_KIND)
                                         LEFT JOIN DPARTY_DBT demi ON (parent_fininstr.T_ISSUER = demi.T_PARTYID)
                                         LEFT JOIN (SELECT t_principal AS t_avr_princ, fininstr.t_FI_Kind,
                                                           tick_ens.t_FIID, fininstr.t_Name,
                                                           fininstr.t_ParentFI, tick_ens.T_DEALID AS T_DEALID,
                                                           tick_ens.T_DATE AS T_DATE,
                                                           fininstr.T_AVOIRKIND AS T_AVOIRKIND,
                                                           parentavoirs.T_NAME AS PARENTAVOIRS_NAME,
                                                           childavoirs_root.T_AVOIRKIND AS childavoirs_root_avoirkind,
                                                           childavoirs_root.T_NAME AS childavoirs_root_avoirkind_name
                                                    FROM ddl_tick_ens_dbt tick_ens
                                                             INNER JOIN dfininstr_dbt fininstr ON fininstr.t_FIID = tick_ens.t_FIID
                                                             LEFT JOIN DAVRKINDS_DBT childavoirs
                                                                       ON (fininstr.T_AVOIRKIND =
                                                                           childavoirs.T_AVOIRKIND AND
                                                                           fininstr.T_FI_KIND = childavoirs.T_FI_KIND)
                                                             LEFT JOIN DAVRKINDS_DBT childavoirs_root
                                                                       ON (childavoirs.T_FI_KIND =
                                                                           childavoirs_root.T_FI_KIND AND
                                                                           childavoirs.T_ROOT =
                                                                           childavoirs_root.T_AVOIRKIND)
                                                             LEFT JOIN DFININSTR_DBT parent_fininstr
                                                                       ON (parent_fininstr.T_FIID =
                                                                           fininstr.T_PARENTFI AND
                                                                           parent_fininstr.T_FI_KIND =
                                                                           fininstr.T_FI_KIND)
                                                             LEFT JOIN DAVRKINDS_DBT parentavoirs
                                                                       ON (parent_fininstr.T_FIID =
                                                                           parentavoirs.T_AVOIRKIND AND
                                                                           parent_fininstr.T_FI_KIND =
                                                                           parentavoirs.T_FI_KIND)) tick_ens
                                                   ON (tick_ens.t_dealid = tick.T_DEALID AND tick_ens.t_date = tick.T_DEALDATE)
                                         CROSS APPLY (SELECT RSB_SECUR.GetObjAttrName(12, 28,
                                                                                      RSB_SECUR.GetMainObjAttr(12,
                                                                                                               TO_CHAR(fininstr.T_FIID, 'FM0000000000'),
                                                                                                               28,
                                                                                                               TO_DATE('31.12.9999', 'dd.MM.yyyy'))) AS name
                                                      FROM DUAL) objectattr
                                         CROSS APPLY (SELECT rsb_secur.IsBasket(rsb_secur.get_OperationGroup(rsb_secur.get_OperSysTypes(tick.t_DealType, tick.t_BofficeKind))) AS isBasket
                                                      FROM DUAL) basket
                                         CROSS APPLY (SELECT CASE
                                                                 WHEN (leg.T_RETURNINCOME <> 0 AND leg.T_LEGKIND = 2)
                                                                     THEN '1'
                                                                 ELSE '0'
                                                             END isBack
                                                      FROM DUAL) isBackTick
                                         CROSS APPLY (SELECT COALESCE(CASE
                                                                          WHEN (isBackTick.isBack = '1')
                                                                              THEN dspdd.T_OLDTOTALCOST2
                                                                          ELSE dspdd.T_OLDTOTALCOST1
                                                                      END, leg.T_TOTALCOST, 0) cost,
                                                             COALESCE(dspdd.T_OLDPRINCIPAL, leg.T_PRINCIPAL, 1) AS principal
                                                      FROM DUAL) total_cost_standart
                                         CROSS APPLY (SELECT (tick_ens.t_avr_princ * total_cost_standart.cost) /
                                                             (total_cost_standart.principal) AS cost
                                                      FROM dual) total_cost_ens
                                         CROSS APPLY (SELECT CASE
                                                                 WHEN (basket.isBasket = 1) THEN total_cost_ens.cost
                                                                 ELSE total_cost_standart.cost
                                                             END AS cost
                                                      FROM dual) total_cost
                                         CROSS APPLY (SELECT COALESCE(
                                                               CASE
                                                                   WHEN (isBackTick.isBack = '1') THEN dspdd.T_OLDCFI2
                                                                   ELSE dspdd.T_OLDCFI1
                                                               END,
                                                               leg.T_CFI, 0) cfi_Value
                                                      FROM DUAL) cfi
                                         CROSS APPLY (SELECT CASE
                                                                 WHEN basket.isBasket = 0 THEN (CASE
                                                                                                    WHEN FININSTR_ROOT.T_AVOIRKIND = 16
                                                                                                        THEN party.T_NAME
                                                                                                    ELSE FININSTR_ROOT.CHILD_NAME
                                                                                                END)
                                                                 ELSE tick_ens.T_NAME
                                                             END name
                                                      FROM DUAL) avrName
                                         CROSS APPLY (SELECT CASE
                                                                 WHEN FININSTR_ROOT.T_AVOIRKIND = 10 THEN (
                                                                     party.T_SHORTNAME || ' на ' ||
                                                                     parent_avoirkinds.T_NAME || ' ' ||
                                                                     demi.T_SHORTNAME)
                                                                 WHEN FININSTR_ROOT.T_AVOIRKIND = 16
                                                                                                     THEN (fininstr.T_NAME)
                                                                 ELSE party.T_NAME
                                                             END AS name
                                                      FROM DUAL) issuerName
                                         CROSS APPLY (SELECT CASE
                                                                 WHEN tick_ens.T_AVOIRKIND = 10 THEN (
                                                                     party.T_SHORTNAME || ' на ' ||
                                                                     tick_ens.PARENTAVOIRS_NAME || ' ' ||
                                                                     demi.T_SHORTNAME)
                                                                 WHEN FININSTR_ROOT.T_AVOIRKIND = 16
                                                                                                THEN (tick_ens.T_NAME)
                                                                 ELSE party.T_NAME
                                                             END AS name
                                                      FROM DUAL) issuerName_ens
                                WHERE (tick.t_BofficeKind = 101 OR tick.t_BofficeKind = 155)
                                  AND tick.t_DealStatus >= 10 AND leg.t_LegKind = 0 AND leg.t_LegID = 0
                                  AND tick.T_DEALTYPE != 32732 AND tick.T_DEALTYPE != 32742
                                  AND (leg.t_RejectDate > v_end_date OR
                                       leg.t_RejectDate = TO_DATE('01.01.0001', 'DD.MM.YYYY'))
                                  AND tick.t_DealDate BETWEEN v_start_date
                                    AND v_end_date
                                  AND tick.t_RequestID = 0
                                  AND rsb_secur.IsOutExchange(
                                        rsb_secur.get_OperationGroup(rsb_secur.get_OperSysTypes(tick.t_DealType, tick.t_BofficeKind)),
                                        1) = 1
                                  AND (
                                    rsb_secur.IsRepo(rsb_secur.get_OperationGroup(rsb_secur.get_OperSysTypes(tick.t_DealType, tick.t_BofficeKind))) =
                                    1
                                        AND (basket.isBasket != 1
                                        OR (basket.isBasket = 1
                                            AND NOT EXISTS (SELECT 1
                                                            FROM dpartyown_dbt partyown
                                                            WHERE partyown.t_PartyKind = 29
                                                              AND partyown.t_PartyID = tick.t_PartyID)))
                                        AND EXISTS (SELECT leg2.t_RejectDate
                                                    FROM ddl_leg_dbt leg2
                                                    WHERE leg2.t_DealID = tick.t_DealID
                                                      AND leg2.t_LegKind = 2
                                                      AND leg2.t_LegID = 0
                                                      AND (leg2.t_RejectDate = TO_DATE('01.01.0001', 'DD.MM.YYYY') OR
                                                           leg2.t_RejectDate >= v_end_date))
                                    )
                                  AND (party.T_NOTRESIDENT <> CHR(88) OR (objectattr.name <> 'Нет'))
                                  AND (FININSTR_ROOT.T_AVOIRKIND = 17 OR FININSTR_ROOT.T_AVOIRKIND = 20 OR
                                       FININSTR_ROOT.T_AVOIRKIND = 16 OR
                                       (FININSTR_ROOT.T_AVOIRKIND = 10 AND fininstr.T_AVOIRKIND = 47)
                                    OR (party.T_NOTRESIDENT = CHR(88) AND
                                        (fininstr.T_AVOIRKIND = 45 OR fininstr.T_AVOIRKIND = 49 OR
                                         fininstr.T_AVOIRKIND = 46)))),
           chapert_2_1      AS (SELECT (t.t_AvrName || ' ' || t.t_ISSUERNAME) AS SecNAme, av.t_LSIN AS gos_num,
                                       av.t_ISIN AS ISIN, t.T_DEALCODE AS dealNum,
                                       t.T_DEALDATE AS dealDate, t.T_CLIRINGDATE AS clrDate, t.T_CLIENTID AS client,
                                       CASE
                                           WHEN (t.t_TypeDeal = 'OWN' AND t.T_BUYSALE = 2) THEN t.T_SUMMA
                                           ELSE 0
                                       END AS ownB,
                                       CASE
                                           WHEN (t.t_TypeDeal = 'OWN' AND t.T_BUYSALE = 1) THEN t.T_SUMMA
                                           ELSE 0
                                       END AS ownS,
                                       CASE
                                           WHEN (t.t_TypeDeal = 'CLIENT' AND t.T_BUYSALE = 2) THEN t.T_SUMMA
                                           ELSE 0
                                       END AS clientB,
                                       CASE
                                           WHEN (t.t_TypeDeal = 'CLIENT' AND t.T_BUYSALE = 1) THEN t.T_SUMMA
                                           ELSE 0
                                       END AS clientS,
                                       t.T_FIID, t.T_NOTRESIDENT, t.T_AVRTYPE,
                                       CASE (t.T_AVRTYPE)
                                           WHEN (20) THEN 1
                                           WHEN (17) THEN 2
                                           WHEN (16) THEN 3
                                           WHEN (5)  THEN 4
                                           WHEN (9)  THEN 5
                                           WHEN (10) THEN 6
                                           ELSE 100 + t.T_AVRTYPE
                                       END AS T_ORDER
                                FROM chapter_2_1_data t, davoiriss_dbt av
                                WHERE t.t_FI_Kind = 2
                                  AND av.t_fiid = t.t_fiid),
           req_result       AS (SELECT r.lvl1 || '.' || r.lvl2 || '.' || r.lvl3 AS num_code, r.*
                                FROM (SELECT ch.*,
                                             DENSE_RANK() OVER (
                                                 ORDER BY ch.T_NOTRESIDENT
                                                 ) AS lvl1,

                                             DENSE_RANK() OVER (
                                                 PARTITION BY ch.T_NOTRESIDENT
                                                 ORDER BY ch.T_ORDER
                                                 ) AS lvl2,

                                             DENSE_RANK() OVER (
                                                 PARTITION BY ch.T_NOTRESIDENT, ch.T_ORDER
                                                 ORDER BY ch.SecNAme, ch.gos_num, ch.ISIN
                                                 ) AS lvl3
                                      FROM chapert_2_1 ch) r
                                ORDER BY r.lvl1, r.lvl2, r.lvl3)
      SELECT (
                 JSON_ARRAYAGG(
                   JSON_OBJECT(
                     'counter' VALUE num_code,
                     'SecNAme' VALUE SecNAme,
                     'gos_num' VALUE gos_num,
                     'ISIN' VALUE ISIN,
                     'dealNum' VALUE dealNum,
                     'dealDate' VALUE dealDate,
                     'clrDate' VALUE clrDate,
                     'client' VALUE client,
                     'ownB' VALUE ownB,
                     'ownS' VALUE ownS,
                     'clientB' VALUE clientB,
                     'clientS' VALUE clientS,
                     'founderB' VALUE 0,
                     'founderS' VALUE 0
                   ) RETURNING CLOB
                 )
                 )
      INTO v_json_output
      FROM (SELECT r.*
            FROM req_result r
            UNION ALL
            -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
            SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                   NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
            FROM dual
            WHERE NOT EXISTS (SELECT 1 FROM req_result));

      v_json_output := BuildSplitJsonOutputWithAdditionalParams(p_trace_id_input => p_trace_id_input,
                                                                p_json_input => v_json_output,
                                                                p_json_addfileds => JSON_ARRAY(JSON_OBJECT('key' VALUE
                                                                                                           'period',
                                                                                                           'value' VALUE
                                                                                                           v_period_str,
                                                                                                           'type' VALUE
                                                                                                           'VARCHAR')),
                                                                p_report_date_input => v_start_date,
                                                                p_report_tag => C_REPORT_NAME_TAG,
                                                                p_items_arr_tag => C_ITEMS_ARR_TAG,
                                                                p_template_name => C_TEMPLATE_NAME,
                                                                p_output_file_name => C_OUTPUT_FILE_NAME,
                                                                p_s3_file_name => C_S3_FILE_NAME);
      RETURN v_json_output;
  END GENERATE_DECRYPT_706_REPORT_CHAPTER_2_1;

  --- UI
  FUNCTION GETDECRYPT706METAUI RETURN CLOB IS
      C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
      C_REPORT_LOCALIZED_NAME VARCHAR2(64)  := 'Расшифровка отчетной формы 0409706';
      C_SYS_TAGS              VARCHAR2(256) := '["ORACLE", "Decrypt"]';
      v_meta_ui               CLOB;
  BEGIN
      WITH years   AS (SELECT EXTRACT(YEAR FROM SYSDATE) - LEVEL + 1 AS years
                       FROM dual
                       CONNECT BY 2019 + LEVEL - 1 <= EXTRACT(YEAR FROM SYSDATE)),
           periods AS (SELECT COLUMN_VALUE AS val, ROWNUM AS row_num FROM TABLE (C_PERIOD)
                       WHERE ROWNUM < 13) -- WHERE ROWNUM < 13 - временно отрезаем кварталы, что бы показывались только месяцы
      SELECT JSON_OBJECT(
               C_META_UI_TAG__ROLES VALUE C_ROLES FORMAT JSON,
               C_META_UI_TAG__LABEL VALUE C_REPORT_LOCALIZED_NAME,
               C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
               C_META_UI_TAG__FORM VALUE JSON_ARRAY(
                   -- Первая строка
                 JSON_ARRAY(
                   JSON_OBJECT(
                     'label' VALUE 'Период',
                     'name' VALUE 'period',
                     'type' VALUE 'select',
                     'required' VALUE 'true' FORMAT JSON,
                     'column' VALUE 0,
                     'default' VALUE
                     (SELECT val
                      FROM (periods) p
                      WHERE p.row_num = (SELECT TO_NUMBER(TO_CHAR(SYSDATE, 'MM')) AS idx FROM DUAL)),
                     'multiselect' VALUE 'false' FORMAT JSON,
                     'items' VALUE (SELECT JSON_ARRAYAGG(
                                             JSON_OBJECT(
                                               'name' VALUE val,
                                               'value' VALUE val
                                             ) RETURNING CLOB
                                           )
                                    FROM periods)
                     RETURNING CLOB
                   ),
                   JSON_OBJECT(
                     'label' VALUE 'Год',
                     'name' VALUE 'year',
                     'type' VALUE 'select',
                     'required' VALUE 'true' FORMAT JSON,
                     'column' VALUE 1,
                     'default' VALUE (SELECT TO_CHAR(SYSDATE, 'YYYY') FROM DUAL),
                     'multiselect' VALUE 'false' FORMAT JSON,
                     'items' VALUE (SELECT JSON_ARRAYAGG(
                                             JSON_OBJECT(
                                               'name' VALUE years,
                                               'value' VALUE years
                                             ) RETURNING CLOB
                                           )
                                    FROM years)
                     RETURNING CLOB
                   )
                 )
                                         ) RETURNING CLOB
             )
      INTO v_meta_ui
      FROM dual;

      RETURN v_meta_ui;
  END GETDECRYPT706METAUI;

  FUNCTION BuildSplitJsonOutputWithAdditionalParams(p_trace_id_input VARCHAR2,
                                                    p_json_input CLOB,
                                                    p_json_addfileds CLOB DEFAULT NULL, -- JSON Массив с описанием доп полей
                                                    p_report_date_input DATE, -- Nullable
                                                    p_report_tag VARCHAR2, -- например: 'GetDepoReport'
                                                    p_items_arr_tag VARCHAR2, -- например: 'Rest_info'
                                                    p_template_name VARCHAR2,
                                                    p_output_file_name VARCHAR2,
                                                    p_s3_file_name VARCHAR2,
                                                    p_report_date_format VARCHAR2 DEFAULT 'YYYY.MM.DD' -- Формат даты в выходном наименовании файла
  )
      RETURN CLOB
      IS
      v_json_output CLOB;
      v_total_parts INTEGER;
  BEGIN
      -- Разбиваем большой JSON на части
      v_total_parts := IT_CHECKLIMITREPORT.SplitJsonArrayIntoParts(p_json_input, C_MAX_DATA_SIZE_PER_PART);

      -- Собираем обратно общий JSON из временной таблицы
      SELECT JSON_ARRAYAGG(
               JSON_OBJECT(
                 C_OUTPUT_TAG__EXMETA VALUE '[]' FORMAT JSON,
                 C_OUTPUT_TAG__HEADERS VALUE IT_CHECKLIMITREPORT.GetDocFactHeaders(
                   p_trace_id_input,
                   p_report_date_input,
                   p_template_name,
                   p_output_file_name,
                   p_s3_file_name,
                   part_num,
                   v_total_parts,
                   IT_XML.TIMESTAMP_TO_CHAR_ISO8601(SYSDATE),
                   p_report_date_format
                                             ) FORMAT JSON,
                 C_OUTPUT_TAG__BODY VALUE JSON_OBJECT(p_report_tag VALUE (SELECT JSON_OBJECTAGG(k VALUE CASE t
                                                                                                            WHEN 'VARCHAR'
                                                                                                                THEN '"' || v || '"'
                                                                                                            WHEN 'JSON'
                                                                                                                THEN v
                                                                                                        END FORMAT JSON
                                                                                                ABSENT ON NULL
                                                                                                RETURNING CLOB)
                                                                          FROM (SELECT 'date' AS k,
                                                                                       TO_CLOB(CASE
                                                                                                   WHEN p_report_date_input IS NOT NULL
                                                                                                       THEN TO_CHAR(p_report_date_input, 'DD.MM.YYYY')
                                                                                               END) AS v, 'VARCHAR' AS t
                                                                                FROM DUAL
                                                                                UNION ALL
                                                                                SELECT jt.name AS k, TO_CLOB(jt.value) AS v, tp AS t
                                                                                FROM JSON_TABLE(
                                                                                       COALESCE(p_json_addfileds, TO_CLOB(JSON_OBJECT())),
                                                                                       '$[*]'
                                                                                       COLUMNS (
                                                                                           name VARCHAR2(200) PATH '$.key',
                                                                                           value VARCHAR2(500) PATH '$.value',
                                                                                           tp VARCHAR2(20) PATH '$.type'
                                                                                           )
                                                                                     ) jt
                                                                                WHERE jt.name IS NOT NULL
                                                                                UNION ALL
                                                                                SELECT p_items_arr_tag AS k, json_part AS v, 'JSON' AS t
                                                                                FROM DUAL)) RETURNING CLOB)
                 RETURNING CLOB format json
               ) RETURNING CLOB
             )
      INTO v_json_output
      FROM dbdui_report_parts_dbt;

      RETURN v_json_output;
  END BuildSplitJsonOutputWithAdditionalParams;

  /**************************************************************************************************\
  [Конец блока] BIQ-23781.5(intech), BIQ-29457.5(avt) Расшифровка отчетной формы 0409706
  \**************************************************************************************************/

  ------------------------------------------------------------------------------
  ----- Формирование UI Form для Отчёта Расшифровка отчетной формы 0409724 -----
  ------------------------------------------------------------------------------
--   FUNCTION Decrypt724ReportMetaUI
--     RETURN CLOB
--   IS
--       C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
--       C_REPORT_LOCALIZED_NAME VARCHAR2(128) := 'Расшифровка отчетной формы 04090724';
--       C_SYS_TAGS              VARCHAR2(256) := '["ORACLE","Decrypt"]';
--       v_meta_ui               CLOB;
--       v_history_start_year    INTEGER := 2019;
--   BEGIN
--       WITH
--           years (value) AS (
--               SELECT v_history_start_year + LEVEL - 1 AS year
--               FROM dual
--               CONNECT BY v_history_start_year + LEVEL - 1 <= EXTRACT(YEAR FROM SYSDATE)
--           ),
--           months (name, value) AS (
--               SELECT
--                   TO_CHAR(
--                           ADD_MONTHS(DATE '0001-01-01', LEVEL - 1),
--                           'FMMonth',
--                           'NLS_DATE_LANGUAGE=RUSSIAN'
--                   ) AS name,
--                   LEVEL AS value
--               FROM dual
--               CONNECT BY LEVEL <= 12
--           ),
--           prev_period AS (
--               SELECT
--                   TO_NUMBER(TO_CHAR(ADD_MONTHS(SYSDATE, -1), 'YYYY')) AS year,
--                   TO_NUMBER(TO_CHAR(ADD_MONTHS(SYSDATE, -1), 'FMMM')) AS month
--               FROM dual
--       )
--       SELECT
--           JSON_OBJECT(
--               C_META_UI_TAG__ROLES   VALUE C_ROLES FORMAT JSON,
--               C_META_UI_TAG__LABEL   VALUE C_REPORT_LOCALIZED_NAME,
--               C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
--               C_META_UI_TAG__FORM    VALUE JSON_ARRAY(
--                   -- Первая строка
--                   JSON_ARRAY(
--                       JSON_OBJECT(
--                           'label'    VALUE 'Период',
--                           'name'     VALUE 'period',
--                           'type'     VALUE 'select',
--                           'required' VALUE 'true' FORMAT JSON,
--                           'column'   VALUE 0,
--                           'default'  VALUE prev_period.month,
--                           'multiselect' VALUE 'false' FORMAT JSON,
--                           'items'       VALUE (
--                               SELECT JSON_ARRAYAGG(
--                                   JSON_OBJECT(
--                                           'name'  VALUE name,
--                                           'value' VALUE value
--                                   ) RETURNING CLOB
--                               )
--                               FROM months
--                           )
--                           RETURNING CLOB
--                       ),
--                       JSON_OBJECT(
--                           'label'    VALUE 'Год',
--                           'name'     VALUE 'year',
--                           'type'     VALUE 'select',
--                           'required' VALUE 'true' FORMAT JSON,
--                           'column'   VALUE 1,
--                           'default'  VALUE prev_period.year,
--                           'multiselect' VALUE 'false' FORMAT JSON,
--                           'items'       VALUE (
--                               SELECT JSON_ARRAYAGG(
--                                   JSON_OBJECT(
--                                       'name'  VALUE value,
--                                       'value' VALUE value
--                                   )
--                                   ORDER BY value DESC
--                                   RETURNING CLOB
--                               )
--                               FROM years
--                           ) RETURNING CLOB
--                       )
--                   )
--               ) RETURNING CLOB
--           )
--       INTO v_meta_ui
--       FROM prev_period;
--
--       RETURN v_meta_ui;
--   END Decrypt724ReportMetaUI;
--
--   ------------------------------------------------------------------
--   ----- Заполнение временных таблиц для отчетной формы 0409724 -----
--   ------------------------------------------------------------------
--   procedure Decrypt724_FillTable(p_trace_id_input VARCHAR2,
--                                 p_rd_from        DATE,
--                                 p_rd_to          DATE,
--                                 p_session_id     INTEGER
--   )
--   IS
--       PRAGMA AUTONOMOUS_TRANSACTION;
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8)  := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: ошибка при заполнении промежуточных таблиц';
--
--       -- Валидация
--       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
--   BEGIN
--     it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено заполнение временных таблиц: Расшифровка отчетной формы 0409724', it_log.C_MSG_TYPE__DEBUG);
--
--     RsbSessionData.SetOurBank(1);
--
--     -- Вызов функций заполенение временных таблиц по аналогии с dl_report724_2026.mac
--     RSB_DL724REP_2026.ClearTables(p_session_id);
--     RSB_DL724REP_2026.FillTableContr(p_session_id, p_rd_from, p_rd_to, 1, 1, 0);
--     RSB_DL724REP_2026.FillTableClient(p_session_id, p_rd_from, p_rd_to, 1, 1, 0);
--     RSB_DL724REP_2026.CreateAllData(p_rd_from, p_rd_to, 0, p_session_id, 12, 0);
--     RSB_DL724REP_2026.FillTableR3CLIENT_GROUP(p_rd_from, p_rd_to, p_session_id, 12);
--
--     COMMIT;
--
--   it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Заполнение временных таблиц закончено: Расшифровка отчетной формы 0409724', it_log.C_MSG_TYPE__DEBUG);
--
--   EXCEPTION
--           WHEN OTHERS THEN
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--   END;
--
-- -------------------------------------------------------------------------------------
--   ----- Формирование Расшифровки по разделу 2 движению д/с отчетная формa 0409724 -----
--   -------------------------------------------------------------------------------------
--   FUNCTION Decrypt724Part2_DS(p_trace_id_input VARCHAR2,
--                               p_rd_to          DATE,
--                               p_session_id     INTEGER
--   )
--     RETURN CLOB
--   IS
--       -- Константы
--       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := '0409724_ch2_ds_decryption';
--       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Расшифровка_0409724_раздел_2_DS';
--       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := '0409724_ch2_DS_decryption';
--       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'chapter_2_DS';
--       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'dataset';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8)  := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: ошибка при формировании расшифровки по разделу 2 движению д/с';
--
--       -- Переменные
--       v_json_output           CLOB;
--
--       -- Валидация
--       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
--   BEGIN
--      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: расшифровки раздела 2 движение д/с', it_log.C_MSG_TYPE__DEBUG);
--    WITH
--      result AS(
--             SELECT DISTINCT
--                    MONEY.T_CLIENT_GROUPID                                                             t_ClGroupCode
--                  , MONEY.T_CONTR_GROUPID                                                              t_DogGroupCode
--                  , CL.T_CLIENTCODE                                                                    t_ClCode
--                  , CL.T_NAME                                                                          t_ClName
--                  , dog.t_number                                                                       t_NumDog
--                  , subDog.t_number                                                                    t_NumSubDog
--                  , MONEY.T_CODE                                                                       t_CodeOp
--                  , (CASE WHEN money.t_wrtin = 'X' THEN 'Зачисление' ELSE 'Списание' END)              t_TypeOp
--                  , MONEY.T_DATE                                                                       t_Date
--                  , FININSTR.T_CCY                                                                     t_NameFI
--                  , MONEY.T_SUM                                                                        t_Sum
--                  , MONEY.T_SUMRUB                                                                     t_SumRub
--             FROM D724WRTMONEY_DBT MONEY
--                      JOIN D724CLIENT_DBT CL
--                           ON CL.T_SESSIONID = p_session_id
--                               AND CL.T_PARTYID = MONEY.T_PARTYID
--                      JOIN D724CONTR_DBT CONTR
--                           ON CONTR.T_SESSIONID = p_session_id
--                               AND CONTR.T_SF_ID = MONEY.T_CONTRID
--                      JOIN d724dlcontr_dbt dl
--                           ON cl.t_partyid = dl.t_partyid
--                               AND dl.t_sessionid = p_session_id
--                               AND CONTR.t_dlcontrid = dl.t_dlcontrid
--                      JOIN DFININSTR_DBT FININSTR
--                           ON FININSTR.T_FIID = MONEY.T_FIID
--                      LEFT JOIN (SELECT t_id, t_number FROM dsfcontr_dbt) dog
--                                ON dog.t_id = contr.t_parent_sf_id
--                      LEFT JOIN (SELECT t_id, t_number FROM dsfcontr_dbt) subDog
--                                ON subDog.t_id = MONEY.t_contrid
--      )
--      SELECT (
--           JSON_ARRAYAGG(
--               JSON_OBJECT(
--                   'ClGroupCode'              VALUE t_ClGroupCode,
--                   'DogGroupCode'             VALUE t_DogGroupCode,
--                   'ClCode'                   VALUE t_ClCode,
--                   'ClName'                   VALUE t_ClName,
--                   'NumDog'                   VALUE t_NumDog,
--                   'NumSubDog'                VALUE t_NumSubDog,
--                   'CodeOp'                   VALUE t_CodeOp,
--                   'TypeOp'                   VALUE t_TypeOp,
--                   'Date'                     VALUE t_Date,
--                   'CurCode'                  VALUE t_NameFI,
--                   'Sum'                      VALUE t_Sum,
--                   'SumRub'                   VALUE t_SumRub
--               ) order by t_DogGroupCode, t_ClGroupCode, t_CodeOp
--               RETURNING CLOB
--           )
--       )
--       INTO v_json_output
--       FROM (
--           SELECT r.*
--           FROM result r
--           UNION ALL
--           -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
--           SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                  NULL, NULL
--           FROM dual
--           WHERE NOT EXISTS (SELECT 1 FROM result)
--       );
--
--       v_json_output := BuildSplitJsonOutput(p_trace_id_input   => p_trace_id_input,
--                                            p_json_input        => v_json_output,
--                                            p_report_date_input => p_rd_to +1,
--                                            p_report_tag        => C_REPORT_NAME_TAG,
--                                            p_items_arr_tag     => C_ITEMS_ARR_TAG,
--                                            p_template_name     => C_TEMPLATE_NAME,
--                                            p_output_file_name  => C_OUTPUT_FILE_NAME,
--                                            p_s3_file_name      => C_S3_FILE_NAME);
--
--       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Расшифровка отчетной формы раздел 2 движение д/с закончена', it_log.C_MSG_TYPE__DEBUG);
--       RETURN v_json_output;
--
--       EXCEPTION
--           WHEN OTHERS THEN
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--
--   END Decrypt724Part2_DS;
--
--   -------------------------------------------------------------------------------------
--   ----- Формирование Расшифровки по разделу 2 движению ц/б отчетная формa 0409724 -----
--   -------------------------------------------------------------------------------------
--   FUNCTION Decrypt724Part2_CB(p_trace_id_input VARCHAR2,
--                               p_rd_to          DATE,
--                               p_session_id     INTEGER
--   )
--     RETURN CLOB
--   IS
--       -- Константы
--       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := '0409724_ch2_cb_decryption';
--       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Расшифровка_0409724_раздел_2_CB';
--       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := '0409724_ch2_CB_decryption';
--       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'chapter_2_CB';
--       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'dataset';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8)  := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: другая ошибка при формировании расшифровки раздела 2 движение ц/б';
--
--       -- Переменные
--       v_json_output           CLOB;
--
--       -- Валидация
--       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
--   BEGIN
--      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Расшифровка отчетной формы раздел 2 движение ц/б', it_log.C_MSG_TYPE__DEBUG);
--
--    WITH
--      result AS(
--              SELECT DISTINCT
--                      WAVR.T_CLIENT_GROUPID                                                                         t_ClGroupCode
--                    , WAVR.T_CONTR_GROUPID                                                                          t_DogGroupCode
--                    , CL.T_CLIENTCODE                                                                               t_ClCode
--                    , CL.T_NAME                                                                                     t_ClName
--                    , dog.t_number                                                                                  t_NumDog
--                    , subDog.t_number                                                                               t_NumSubDog
--                    , WAVR.T_CODE                                                                                   t_CodeOp
--                    , (CASE WHEN WAVR.t_wrtin = 'X' THEN 'Зачисление' ELSE 'Списание' END)                          t_TypeOp
--                    , WAVR.T_DATE                                                                                   t_Date
--                    , FININSTR.T_NAME                                                                               t_NameFI
--                    , FACEFIN.T_CCY                                                                                 t_CurNom
--                    , AVR.T_ISIN                                                                                    t_ISIN
--                    -- IMPROVE724 Есть большие опасения по поводу этой выборки, по сути, у нас же выборка только за месяц?
--                    -- Если да, то у нас будет всего-лишь 31 уникальных T_FIID, но в текущем варианте, мы прогоним весь запрос + RSB_SECUR.GetMainObjAttr для КАЖДОЙ D724WRTAVR_DBT строки. Это может жёстко ударить по производительности.
--                    -- В общем, если запрос быстрый и записей не много, можно забить.
--                    -- Если запрос медленный (много записей в D724WRTAVR_DBT), предлагаю такое решение: т.к. даты нам заранее известны (ну либо select distinct t_date from D724WRTAVR_DBT where WAVR.T_SESSIONID = v_session_id), то мы делаем предварительно CTE, где заранее рассчитаем t_TypeFI для каждой даты, а в основном запросе уже будет обращаться к нашему CTE по дате за конкретным значением без дополнительного рассчёта
--                    , (SELECT t_name
--                       FROM dobjattr_dbt
--                       WHERE t_objecttype=12
--                         AND t_groupid=1
--                         AND t_attrid=RSB_SECUR.GetMainObjAttr (12, LPAD (WAVR.T_FIID, 10, '0'), 1,WAVR.T_DATE))    t_TypeFI
--                    , WAVR.T_QNTY                                                                                   t_Quantity
--                    , WAVR.T_RATE                                                                                   t_DateCur
--                    , WAVR.T_TOTALCOST                                                                              t_Amount
--                    , WAVR.T_COSTNRUR                                                                               t_Sum
--                    , PRICEFIN.T_CCY                                                                                t_CurPrice
--                    , WAVR.T_NKD                                                                                    t_NDK
--                    , WAVR.T_NKDNRUR                                                                                t_NDKRub
--                    , WAVR.T_TOTALCOST - WAVR.T_NKD                                                                 t_AmountWithoutNDK
--                    , WAVR.T_COSTNRUR - WAVR.T_NKDNRur                                                              t_AmountWithoutNDKRub
--               FROM D724WRTAVR_DBT WAVR
--               JOIN D724CLIENT_DBT CL
--                 ON CL.T_SESSIONID = p_session_id
--                AND CL.T_PARTYID = WAVR.T_PARTYID
--               JOIN D724CONTR_DBT CONTR
--                 ON CONTR.T_SESSIONID = p_session_id
--                AND CONTR.T_SF_ID = WAVR.T_CONTRID
--               JOIN d724dlcontr_dbt dl
--                 ON cl.t_partyid = dl.t_partyid
--                AND dl.t_sessionid = p_session_id
--                AND CONTR.t_dlcontrid = dl.t_dlcontrid
--               JOIN d724r3client_group r3
--                 ON r3.t_sessionid = p_session_id
--                AND r3.t_client_groupid = WAVR.t_client_groupid
--                AND r3.t_partyid = WAVR.t_partyid
--               LEFT JOIN DFININSTR_DBT PRICEFIN
--                 ON PRICEFIN.T_FIID = WAVR.T_PRICEFIID
--               JOIN DFININSTR_DBT FININSTR
--                 ON FININSTR.T_FIID = WAVR.T_FIID
--               JOIN DAVOIRISS_DBT AVR
--                 ON AVR.T_FIID = WAVR.T_FIID
--               JOIN DFININSTR_DBT FACEFIN
--                 ON FACEFIN.T_FIID = FININSTR.T_FACEVALUEFI
--               LEFT JOIN (SELECT t_id, t_number FROM dsfcontr_dbt) dog
--                 ON dog.t_id = contr.t_parent_sf_id
--               LEFT JOIN (SELECT t_id, t_number FROM dsfcontr_dbt) subDog
--                 ON subDog.t_id = WAVR.t_contrid
--      )
--      SELECT (
--           JSON_ARRAYAGG(
--               JSON_OBJECT(
--                   'ClGroupCode'              VALUE t_ClGroupCode,
--                   'DogGroupCode'             VALUE t_DogGroupCode,
--                   'ClCode'                   VALUE t_ClCode,
--                   'ClName'                   VALUE t_ClName,
--                   'NumDog'                   VALUE t_NumDog,
--                   'NumSubDog'                VALUE t_NumSubDog,
--                   'CodeOp'                   VALUE t_CodeOp,
--                   'TypeOp'                   VALUE t_TypeOp,
--                   'Date'                     VALUE t_Date,
--                   'NameFI'                   VALUE t_NameFI,
--                   'CurNom'                   VALUE t_CurNom,
--                   'ISIN'                     VALUE t_ISIN,
--                   'TypeFI'                   VALUE t_TypeFI,
--                   'Quantity'                 VALUE t_Quantity,
--                   'DateCur'                  VALUE t_DateCur,
--                   'Amount'                   VALUE t_Amount,
--                   'Sum'                      VALUE t_Sum,
--                   'CurPrice'                 VALUE t_CurPrice,
--                   'NDK'                      VALUE t_NDK,
--                   'NDKRub'                   VALUE t_NDKRub,
--                   'AmountWithoutNDK'         VALUE t_AmountWithoutNDK,
--                   'AmountWithoutNDKRub'      VALUE t_AmountWithoutNDKRub
--               ) RETURNING CLOB
--           )
--       )
--      INTO v_json_output
--       FROM (
--           SELECT r.*
--           FROM result r
--           UNION ALL
--           -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
--           SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                  NULL, NULL
--           FROM dual
--           WHERE NOT EXISTS (SELECT 1 FROM result)
--       );
--
--      v_json_output := BuildSplitJsonOutput(p_trace_id_input    => p_trace_id_input,
--                                            p_json_input        => v_json_output,
--                                            p_report_date_input => p_rd_to +1,
--                                            p_report_tag        => C_REPORT_NAME_TAG,
--                                            p_items_arr_tag     => C_ITEMS_ARR_TAG,
--                                            p_template_name     => C_TEMPLATE_NAME,
--                                            p_output_file_name  => C_OUTPUT_FILE_NAME,
--                                            p_s3_file_name      => C_S3_FILE_NAME);
--
--      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Расшифровка отчетной формы раздел 2 движение ц/б закончена', it_log.C_MSG_TYPE__DEBUG);
--      RETURN v_json_output;
--
--      EXCEPTION
--           WHEN OTHERS THEN
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--
--   END Decrypt724Part2_CB;
--
--   --------------------------------------------------------------------------------
--   ----- Формирование Расшифровки по разделу 2 инд.код отчетная формa 0409724 -----
--   --------------------------------------------------------------------------------
--   FUNCTION Decrypt724Part2_IndCode(p_trace_id_input VARCHAR2,
--                                    p_rd_to          DATE,
--                                    p_session_id     INTEGER
--   )
--     RETURN CLOB
--   IS
--       -- Константы
--       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := '0409724_ch2_ik_decryption';
--       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Расшифровка_0409724_раздел_2_IK';
--       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := '0409724_ch2_IK_decryption';
--       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'chapter_2_IK';
--       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'dataset';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8)  := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: другая ошибка при формировании расшифровки раздела 2 инд.код';
--
--       -- Переменные
--       v_json_output           CLOB;
--
--       -- Валидация
--       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
--   BEGIN
--      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Расшифровка отчетной формы раздел 2 инд.код', it_log.C_MSG_TYPE__DEBUG);
--
--    WITH
--      result AS(
--             SELECT DISTINCT
--                    dl.t_code_portfolio                                                    t_ClGroupCode
--                  , cr.t_contr_groupid                                                     t_DogGroupCode
--                  , cl.t_clientcode                                                        t_ClCode
--                  , cl.t_name                                                              t_ClName
--                  , cl.t_code_oksm                                                         t_Country
--                  , (CASE WHEN t_type_fl = 1 THEN 'ЮР' ELSE 'ФИЗ' END)                     t_RegType
--                  , cr.t_Category_CONTR                                                    t_FlagIP
--                  , (CASE WHEN t_ki = 1 THEN 'КВАЛ' ELSE 'НЕКВАЛ' END)                     t_InvCval
--                  , (CASE WHEN dl.t_active = 1 THEN 'Активный' ELSE 'Неактивный' END)      t_ActState
--                  , cl.t_code_oksm                                                         t_OKMS
--                  , t_code_okato                                                           t_OKATO
--                  , pcontr.t_number                                                        t_DogNum
--                  , pcontr.t_datebegin                                                     t_OpenDate
--                  , (CASE WHEN pcontr.t_dateclose > p_rd_to
--                         THEN TO_DATE('01.01.0001', 'DD.MM.YYYY')
--                         ELSE pcontr.t_dateclose
--                    END)                                                                   t_CloseDate
--                  , (CASE WHEN cr.t_iis = 1 THEN 'X' ELSE NULL END)                        t_FlagIIS
--                  , (CASE WHEN t_bankrole = 1 THEN 'Да' ELSE 'Нет' END)                    t_FinAct
--                  , (SELECT Attr.t_NumInList
--                     FROM dobjatcor_dbt AtCor, dobjattr_dbt Attr, DDLCONTRMP_DBT mp
--                     WHERE mp.T_SFCONTRID = t_sf_id
--                       AND AtCor.t_ObjectType = 207
--                       AND AtCor.t_GroupID    = 199 /*ОКВЭД для 724 ф*/
--                       AND AtCor.t_Object     = LPAD(mp.T_DLCONTRID , 34, '0' )
--                       AND AtCor.t_ValidFromDate  = ( SELECT MAX(t.T_ValidFromDate)
--                                                      FROM DOBJATCOR_DBT t
--                                                      WHERE t.T_ObjectType = AtCor.T_ObjectType
--                                                        AND t.T_GroupID    = AtCor.T_GroupID
--                                                        AND t.t_Object     = AtCor.t_Object
--                                                        AND t.T_ValidFromDate <= p_rd_to
--                                                        AND (    t.T_ValidToDate >= p_rd_to
--                                                              OR t.T_ValidToDate = TO_DATE('01.01.0001', 'DD.MM.YYYY') )
--                                                    )
--                       AND (    AtCor.T_ValidToDate >= p_rd_to
--                             OR AtCor.T_ValidToDate = TO_DATE('01.01.0001', 'DD.MM.YYYY') )
--                       AND Attr.t_AttrID      = AtCor.t_AttrID
--                       AND Attr.t_ObjectType  = AtCor.t_ObjectType
--                       AND Attr.t_GroupID     = AtCor.t_GroupID
--                       AND ROWNUM = 1)                                                     t_OKVED2
--             FROM d724contr_dbt cr, d724dlcontr_dbt dl, d724client_dbt cl, dsfcontr_dbt pcontr
--             WHERE cr.t_sessionid = p_session_id
--               AND dl.t_sessionid = p_session_id
--               AND cl.t_sessionid = p_session_id
--               AND cr.t_dlcontrid = dl.t_dlcontrid
--               AND dl.t_partyid = cl.t_partyId
--               AND pcontr.t_id = cr.t_parent_sf_id
--      )
--      SELECT (
--           JSON_ARRAYAGG(
--               JSON_OBJECT(
--                   'ClGroupCode'              VALUE t_ClGroupCode,
--                   'DogGroupCode'             VALUE t_DogGroupCode,
--                   'ClCode'                   VALUE t_ClCode,
--                   'ClName'                   VALUE t_ClName,
--                   'Country'                  VALUE t_Country,
--                   'RegType'                  VALUE t_RegType,
--                   'FlagIP'                   VALUE t_FlagIP,
--                   'InvCval'                  VALUE t_InvCval,
--                   'ActState'                 VALUE t_ActState,
--                   'OKMS'                     VALUE t_OKMS,
--                   'OKATO'                    VALUE t_OKATO,
--                   'DogNum'                   VALUE t_DogNum,
--                   'OpenDate'                 VALUE t_OpenDate,
--                   'CloseDate'                VALUE t_CloseDate,
--                   'FlagIIS'                  VALUE t_FlagIIS,
--                   'FinAct'                   VALUE t_FinAct,
--                   'OKVED2'                   VALUE t_OKVED2
--               ) ORDER BY t_ClGroupCode, t_DogGroupCode, t_ClCode, t_DogNum
--               RETURNING CLOB
--           )
--       )
--      INTO v_json_output
--       FROM (
--           SELECT r.*
--           FROM result r
--           UNION ALL
--           -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
--           SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                  NULL, NULL, NULL, NULL, NULL, NULL, NULL
--           FROM dual
--           WHERE NOT EXISTS (SELECT 1 FROM result)
--       );
--
--       v_json_output := BuildSplitJsonOutput(p_trace_id_input   => p_trace_id_input,
--                                            p_json_input        => v_json_output,
--                                            p_report_date_input => p_rd_to +1,
--                                            p_report_tag        => C_REPORT_NAME_TAG,
--                                            p_items_arr_tag     => C_ITEMS_ARR_TAG,
--                                            p_template_name     => C_TEMPLATE_NAME,
--                                            p_output_file_name  => C_OUTPUT_FILE_NAME,
--                                            p_s3_file_name      => C_S3_FILE_NAME);
--
--      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Расшифровка отчетной формы раздел 2 инд.код закончена', it_log.C_MSG_TYPE__DEBUG);
--      RETURN v_json_output;
--
--      EXCEPTION
--           WHEN OTHERS THEN
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--
--   END Decrypt724Part2_IndCode;
--
--   ----------------------------------------------------------------------------
--   ----- Формирование Расшифровки по разделу 2 и 3 отчетная формa 0409724 -----
--   ----------------------------------------------------------------------------
--   FUNCTION Decrypt724Part2_3(p_trace_id_input VARCHAR2,
--                              p_rd_from        DATE,
--                              p_rd_to          DATE,
--                              p_session_id     INTEGER
--   )
--     RETURN CLOB
--   IS
--       -- Константы
--       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := '0409724_ch2_and_3_decryption';
--       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Расшифровка_0409724_раздел_2_3';
--       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := '0409724_ch2_and_3_decryption';
--       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'chapter_2_and_3';
--       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'dataset';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8)  := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: другая ошибка при формировании расшифровки раздела 2 и 3';
--
--       -- Переменные
--       v_json_output           CLOB;
--
--       -- Валидация
--       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
--   BEGIN
--      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Расшифровка отчетной формы раздел 2 и 3', it_log.C_MSG_TYPE__DEBUG);
--
--    WITH
--      result AS(
--             SELECT distinct
--                    cr.t_client_groupid                                            t_ClGroupCode
--                  , cr.t_contr_groupid                                             t_DogGroupCode
--                  , cr.t_clientcode                                                t_ClCode
--                  , cr.t_name                                                      t_ClName
--                  --  -- IMPROVE724 Можно попробовать вынести в отдельный CTE, думаю, должно, сильно ускорить запрос. как-нибудь так например:
--                 /*
--                   SELECT
--                         t_sessionid,
--                         t_contr_groupid,
--                         t_dlcontrid,
--                         t_party,
--                         COUNT(DISTINCT CASE
--                             WHEN t_psf_beg < v_rd_from
--                             THEN t_parent_sf_id
--                         END) t_DBObegin,
--                         COUNT(DISTINCT CASE
--                             WHEN t_psf_beg BETWEEN v_rd_from AND v_rd_to
--                             THEN t_parent_sf_id
--                         END) t_DBOnew,
--                         COUNT(DISTINCT CASE
--                             WHEN t_psf_end BETWEEN v_rd_from AND v_rd_to
--                             THEN t_parent_sf_id
--                         END) t_DBOstop,
--                         COUNT(DISTINCT CASE
--                             WHEN t_psf_end > v_rd_from
--                               OR t_psf_end = DATE '0001-01-01'
--                             THEN t_parent_sf_id
--                         END) t_DBOend
--                   FROM D724CONTR_DBT
--                   WHERE t_sessionid = v_session_id
--                   GROUP BY
--                         t_sessionid
--                       , t_contr_groupid
--                       , t_dlcontrid
--                       , t_party
--                 */
--                  , (SELECT COUNT(DISTINCT CONTR1.T_PARENT_SF_ID)
--                     FROM D724CONTR_DBT CONTR1
--                     WHERE CONTR1.T_SESSIONID   = CR.T_SESSIONID
--                       AND CONTR1.T_CONTR_GROUPID = CR.T_CONTR_GROUPID
--                       AND CONTR1.t_dlcontrid = CR.t_dlcontrid
--                       AND CONTR1.T_PARTY = CR.T_PARTYID
--                       AND CONTR1.T_PSF_BEG < p_rd_from
--                    )                                                              t_DBObegin
--                  , (SELECT COUNT(DISTINCT CONTR1.T_PARENT_SF_ID)
--                     FROM D724CONTR_DBT CONTR1
--                     WHERE CONTR1.T_SESSIONID   = CR.T_SESSIONID
--                       AND CONTR1.T_CONTR_GROUPID = CR.T_CONTR_GROUPID
--                       AND CONTR1.t_dlcontrid = CR.t_dlcontrid
--                       AND CONTR1.T_PARTY = CR.T_PARTYID
--                       AND (CONTR1.T_PSF_BEG BETWEEN p_rd_from AND p_rd_to )
--                    )                                                              t_DBOnew
--                  , (SELECT COUNT(DISTINCT CONTR1.T_PARENT_SF_ID)
--                     FROM D724CONTR_DBT CONTR1
--                     WHERE CONTR1.T_SESSIONID   = CR.T_SESSIONID
--                       AND CONTR1.T_CONTR_GROUPID = CR.T_CONTR_GROUPID
--                       AND CONTR1.t_dlcontrid = CR.t_dlcontrid
--                       AND CONTR1.T_PARTY = CR.T_PARTYID
--                       AND (CONTR1.T_PSF_END BETWEEN p_rd_from AND p_rd_to )
--                    )                                                              t_DBOstop
--                  , (SELECT COUNT(DISTINCT CONTR1.T_PARENT_SF_ID)
--                     FROM D724CONTR_DBT CONTR1
--                     WHERE CONTR1.T_SESSIONID   = CR.T_SESSIONID
--                       AND CONTR1.T_CONTR_GROUPID = CR.T_CONTR_GROUPID
--                       AND CONTR1.t_dlcontrid = CR.t_dlcontrid
--                       AND CONTR1.T_PARTY = CR.T_PARTYID
--                       AND (CONTR1.T_PSF_END > p_rd_from
--                         or CONTR1.T_PSF_END = TO_DATE('01.01.0001','DD.MM.YYYY'))
--                    )                                                              t_DBOend
--             FROM (
--                 SELECT dl.t_code_portfolio t_client_groupid
--                      , cr.t_contr_groupid
--                      , cl.t_clientcode
--                      , cl.t_name
--                      , cl.t_partyid
--                      , dl.t_dlcontrid
--                      , cl.t_sessionid
--                 FROM d724client_dbt cl
--                 JOIN d724dlcontr_dbt dl
--                    on dl.t_sessionid = p_session_id
--                   and dl.t_partyId = cl.t_partyid
--                 JOIN d724contr_dbt cr
--                    on cr.t_sessionid = p_session_id
--                   and dl.t_dlcontrid = cr.t_dlcontrid
--                 WHERE cl.t_sessionid = p_session_id
--             ) CR
--      )
--      SELECT (
--           JSON_ARRAYAGG(
--               JSON_OBJECT(
--                   'ClGroupCode'              VALUE t_ClGroupCode,
--                   'DogGroupCode'             VALUE t_DogGroupCode,
--                   'ClCode'                   VALUE t_ClCode,
--                   'ClName'                   VALUE t_ClName,
--                   'DBObegin'                 VALUE t_DBObegin,
--                   'DBOnew'                   VALUE t_DBOnew,
--                   'DBOstop'                  VALUE t_DBOstop,
--                   'DBOend'                   VALUE t_DBOend
--               ) ORDER BY t_ClGroupCode, t_DogGroupCode, t_ClCode, t_ClName
--               RETURNING CLOB
--           )
--       )
--      INTO v_json_output
--       FROM (
--           SELECT r.*
--           FROM result r
--           UNION ALL
--           -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
--           SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
--           FROM dual
--           WHERE NOT EXISTS (SELECT 1 FROM result)
--       );
--
--      v_json_output := BuildSplitJsonOutput(p_trace_id_input    => p_trace_id_input,
--                                            p_json_input        => v_json_output,
--                                            p_report_date_input => p_rd_to +1,
--                                            p_report_tag        => C_REPORT_NAME_TAG,
--                                            p_items_arr_tag     => C_ITEMS_ARR_TAG,
--                                            p_template_name     => C_TEMPLATE_NAME,
--                                            p_output_file_name  => C_OUTPUT_FILE_NAME,
--                                            p_s3_file_name      => C_S3_FILE_NAME);
--
--      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Расшифровка отчетной формы раздел 2 и 3 закончена', it_log.C_MSG_TYPE__DEBUG);
--      RETURN v_json_output;
--
--      EXCEPTION
--           WHEN OTHERS THEN
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--
--   END Decrypt724Part2_3;
--
--   ------------------------------------------------------------------------
--   ----- Формирование Расшифровки по разделу 3 отчетная формa 0409724 -----
--   ------------------------------------------------------------------------
--   FUNCTION Decrypt724Part3(p_trace_id_input VARCHAR2,
--                            p_rd_to          DATE,
--                            p_session_id     INTEGER
--   )
--     RETURN CLOB
--   IS
--       -- Константы
--       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := '0409724_ch3_decryption';
--       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Расшифровка_0409724_раздел_3';
--       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := '0409724_ch3_decryption';
--       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'chapter_3';
--       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'dataset';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8)  := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: другая ошибка при формировании расшифровки раздела 3';
--
--       -- Переменные
--       v_json_output           CLOB;
--
--       -- Валидация
--       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
--   BEGIN
--      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Расшифровка отчетной формы раздел 3', it_log.C_MSG_TYPE__DEBUG);
--    WITH
--      result AS(
--             SELECT DISTINCT
--                    dl.t_code_portfolio                                                    t_ClGroupCode
--                  , cl.t_clientcode                                                        t_ClCode
--                  , cl.t_name                                                              t_ClName
--                  , r3.t_acckind                                                           t_ClBalance
--                  , dl.t_contr                                                             t_ClCountEnd
--                  , dl.t_iiscontr                                                          t_IISonEnd
--                  , CASE WHEN dl.t_begcontr > dl.t_periodstartcontr THEN 1 ELSE 0 END      t_OpenDBO
--                  , CASE WHEN dl.t_endcontr > dl.t_periodendcontr THEN 1 ELSE 0 END        t_CloseDBO
--             FROM d724client_dbt cl
--             JOIN d724dlcontr_dbt dl ON cl.t_partyid = dl.t_partyid
--             LEFT JOIN d724r3client_group r3 ON r3.t_client_groupid = dl.t_code_portfolio  AND r3.t_partyid = cl.t_partyid
--             WHERE cl.t_sessionid = p_session_id
--             ORDER BY dl.t_code_portfolio,
--                      cl.t_clientcode,
--                      cl.t_name
--      )
--      SELECT (
--           JSON_ARRAYAGG(
--               JSON_OBJECT(
--                   'ClGroupCode'              VALUE t_ClGroupCode,
--                   'ClCode'                   VALUE t_ClCode,
--                   'ClName'                   VALUE t_ClName,
--                   'ClBalance'                VALUE t_ClBalance,
--                   'ClCountEnd'               VALUE t_ClCountEnd,
--                   'IISonEnd'                 VALUE t_IISonEnd,
--                   'OpenDBO'                  VALUE t_OpenDBO,
--                   'CloseDBO'                 VALUE t_CloseDBO
--               ) order by t_ClGroupCode, t_ClCode, t_ClName
--               RETURNING CLOB
--           )
--       )
--      INTO v_json_output
--       FROM (
--           SELECT r.*
--           FROM result r
--           UNION ALL
--           -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
--           SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
--           FROM dual
--           WHERE NOT EXISTS (SELECT 1 FROM result)
--       );
--
--      v_json_output := BuildSplitJsonOutput(p_trace_id_input    => p_trace_id_input,
--                                            p_json_input        => v_json_output,
--                                            p_report_date_input => p_rd_to +1,
--                                            p_report_tag        => C_REPORT_NAME_TAG,
--                                            p_items_arr_tag     => C_ITEMS_ARR_TAG,
--                                            p_template_name     => C_TEMPLATE_NAME,
--                                            p_output_file_name  => C_OUTPUT_FILE_NAME,
--                                            p_s3_file_name      => C_S3_FILE_NAME);
--      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Расшифровка отчетной формы раздел 3 закончена', it_log.C_MSG_TYPE__DEBUG);
--      RETURN v_json_output;
--
--      EXCEPTION
--           WHEN OTHERS THEN
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--
--   END Decrypt724Part3;
--
--   ------------------------------------------------------------------------
--   ----- Формирование Расшифровки по разделу 4 отчетная формa 0409724 -----
--   ------------------------------------------------------------------------
--   FUNCTION Decrypt724Part4(p_trace_id_input VARCHAR2,
--                            p_rd_to          DATE,
--                            p_session_id     INTEGER
--   )
--     RETURN CLOB
--   IS
--       -- Константы
--       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := '0409724_ch4_decryption';
--       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Расшифровка_0409724_раздел_4';
--       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := '0409724_ch4_decryption';
--       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'chapter_4';
--       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'dataset';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8)  := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: другая ошибка при формировании расшифровки раздела 4';
--
--       -- Переменные
--       v_json_output           CLOB;
--
--       -- Валидация
--       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
--   BEGIN
--      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Расшифровка отчетной формы раздел 4', it_log.C_MSG_TYPE__DEBUG);
--
--    WITH
--      result AS(
--             SELECT DISTINCT
--                     rest.t_client_groupid                                                 t_ClGroupCode
--                   , rest.t_contr_groupid                                                  t_ClDogGroupCode
--                   , cl.t_clientcode                                                       t_ClCode
--                   , cl.t_name                                                             t_ClName
--                   , dog.t_number                                                          t_NumDog
--                   , subDog.t_number                                                       t_NumSubDog
--                   , rest.t_account                                                        t_BrokerBal
--                   , rest.t_amount_fiid                                                    t_Rest
--                   , fin.t_ccy                                                             t_CurCode
--                   , rest.t_amount_rur                                                     t_RestRub
--                   , dl.t_coderisk                                                         t_ClBalance
--             FROM d724accrest_dbt rest
--                      LEFT JOIN d724client_dbt cl
--                                ON cl.t_sessionid = p_session_id
--                                    AND cl.t_partyid = rest.t_partyid
--                      LEFT JOIN d724contr_dbt cr
--                                ON cr.t_sessionid = p_session_id
--                                    AND cr.t_sf_id = rest.t_contrid
--                      JOIN d724dlcontr_dbt dl
--                           ON cl.t_partyid = dl.t_partyid
--                               AND dl.t_sessionid = p_session_id
--                               AND cr.t_dlcontrid = dl.t_dlcontrid
--                      LEFT JOIN d724r3client_group r3
--                                ON r3.t_sessionid = p_session_id
--                                    AND r3.t_client_groupid = rest.t_client_groupid
--                                    AND r3.t_partyid = rest.t_partyid
--                      LEFT JOIN dfininstr_dbt fin
--                                ON fin.t_fiid = rest.t_fiid
--                      LEFT JOIN (SELECT t_id, t_number FROM dsfcontr_dbt) dog
--                                ON dog.t_id = cr.t_parent_sf_id
--                      LEFT JOIN (SELECT t_id, t_number FROM dsfcontr_dbt) subDog
--                                ON subDog.t_id = rest.t_contrid
--             WHERE rest.t_Sessionid = p_session_id
--               AND rest.T_FI_KIND = 1
--      )
--      SELECT (
--           JSON_ARRAYAGG(
--               JSON_OBJECT(
--                   'ClGroupCode'              VALUE t_ClGroupCode,
--                   'DogGroupCode'             VALUE t_ClDogGroupCode,
--                   'ClCode'                   VALUE t_ClCode,
--                   'ClName'                   VALUE t_ClName,
--                   'NumDog'                   VALUE t_NumDog,
--                   'NumSubDog'                VALUE t_NumSubDog,
--                   'BrokerBal'                VALUE t_BrokerBal,
--                   'Rest'                     VALUE t_Rest,
--                   'CurCode'                  VALUE t_CurCode,
--                   'RestRub'                  VALUE t_RestRub,
--                   'ClBalance'                VALUE t_ClBalance
--               ) order by t_ClGroupCode, t_ClDogGroupCode, t_CurCode, t_BrokerBal
--               RETURNING CLOB
--           )
--       )
--      INTO v_json_output
--       FROM (
--           SELECT r.*
--           FROM result r
--           UNION ALL
--           -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
--           SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                  NULL
--           FROM dual
--           WHERE NOT EXISTS (SELECT 1 FROM result)
--       );
--
--      v_json_output := BuildSplitJsonOutput(p_trace_id_input    => p_trace_id_input,
--                                            p_json_input        => v_json_output,
--                                            p_report_date_input => p_rd_to +1,
--                                            p_report_tag        => C_REPORT_NAME_TAG,
--                                            p_items_arr_tag     => C_ITEMS_ARR_TAG,
--                                            p_template_name     => C_TEMPLATE_NAME,
--                                            p_output_file_name  => C_OUTPUT_FILE_NAME,
--                                            p_s3_file_name      => C_S3_FILE_NAME);
--      it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Расшифровка отчетной формы раздел 4 закончена', it_log.C_MSG_TYPE__DEBUG);
--      RETURN v_json_output;
--
--      EXCEPTION
--           WHEN OTHERS THEN
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--
--   END Decrypt724Part4;
--
--   ---------------------------------------------------------------------------
--   ----- Формирование Расшифровки по разделам 6-7 отчетная формa 0409724 -----
--   ---------------------------------------------------------------------------
--   FUNCTION Decrypt724Part6_7(p_trace_id_input VARCHAR2,
--                              p_rd_to          DATE,
--                              p_session_id     INTEGER
--   )
--     RETURN CLOB
--   IS
--       -- Константы
--       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := '0409724_ch6_and_7_decryption';
--       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Расшифровка_0409724_раздел_6_7';
--       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := '0409724_ch6_and_7_decryption';
--       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'chapter_6_7';
--       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'dataset';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8)  := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: другая ошибка при формировании расшифровки раздела 6 и 7';
--
--       -- Переменные
--       v_json_output           CLOB;
--
--       -- Валидация
--       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
--   BEGIN
--     it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Расшифровка отчетной формы раздел 6 и 7', it_log.C_MSG_TYPE__DEBUG);
--
--   WITH
--     result AS(
--            SELECT DISTINCT
--                   firest.t_client_groupid                                                                 t_ClGroupCode
--                 , firest.t_contr_groupid                                                                  t_DogGroupCode
--                 , cl.t_clientcode                                                                         t_ClCode
--                 , cl.t_name                                                                               t_ClName
--                 , pcontr.t_number                                                                         t_NumDog
--                 , (select t_number from dsfcontr_dbt where t_id = firest.t_contrid)                       t_NumSubDog
--                 , fin.t_name                                                                              t_SecName
--                 , firest.t_LSIN                                                                           t_SecRegNum
--                 , firest.t_ISIN                                                                           t_ISIN
--                 , COALESCE(avrkindsroot.t_name, '')                                                       t_SecCat
--                 , firest.t_IssuerName                                                                     t_EmiName
--                 , firest.t_IssuerOKSMO                                                                    t_EmiCountryCode
--                 , firest.t_AvrType                                                                        t_SecType
--                 , firest.t_account                                                                        t_VYBal
--                 , ToLocalNumber(firest.t_qnty)                                                            t_Quantity
--                 , firest.t_IsNotAvr                                                                       t_NFI
--                 , fin.t_facevalue                                                                         t_Nom
--                 , facefi.t_CCY                                                                            t_CurNom
--                 , COALESCE(rsb_dl724rep_2026.ConvSum(fin.t_facevalue, fin.t_facevaluefi, 0, p_rd_to), 0)  t_NomRub
--                 , firest.t_price                                                                          t_MarketPrice
--                 , pricefi.t_CCY                                                                           t_CurPrice
--                 , firest.t_PriceRub                                                                       t_MarketPriceRub
--                 , firest.t_NKD                                                                            t_NKDRub
--                 , firest.t_totalcost                                                                      t_Amount
--                 , dl.t_coderisk                                                                           t_ClBalance
--            FROM d724firest_dbt firest
--                     JOIN (SELECT t_partyid, t_clientcode, t_name FROM d724client_dbt) cl
--                          ON cl.t_partyid = firest.t_partyid
--                     JOIN (SELECT t_sf_id, t_dlcontrid, t_parent_sf_id FROM d724contr_dbt) cr
--                          ON cr.t_sf_id = firest.t_contrid
--                     JOIN (SELECT t_dlcontrid, t_coderisk FROM d724DLcontr_dbt) dl
--                          ON dl.t_dlcontrid = cr.t_dlcontrid
--                /*join (select t_client_groupid, t_partyid from d724r3client_group) r3
--                  on r3.t_client_groupid = firest.t_client_groupid
--                 and r3.t_partyid = firest.t_partyid*/
--                     JOIN (SELECT t_fiid, t_name, t_facevalue, t_facevaluefi, t_issuer, t_fi_kind, t_avoirkind
--                           FROM dfininstr_dbt) fin
--                          ON fin.t_fiid = firest.t_fiid
--                --join davoiriss_dbt avr on avr.t_fiid = firest.t_fiid
--                     JOIN (SELECT t_id, t_number FROM dsfcontr_dbt) pcontr
--                          ON pcontr.t_id = cr.t_parent_sf_id
--                     LEFT JOIN (SELECT t_fiid, t_CCY FROM dfininstr_dbt) pricefi
--                               ON pricefi.t_fiid = firest.t_pricefi
--                     LEFT JOIN (SELECT t_fiid, t_CCY FROM dfininstr_dbt) facefi
--                               ON facefi.t_fiid = fin.t_facevaluefi
--                --left join dparty_dbt issuer on fin.t_issuer = issuer.t_partyid
--                     LEFT JOIN (SELECT t_fi_kind, t_avoirkind, t_name FROM davrkinds_dbt) avrkindsroot
--                               ON avrkindsroot.t_fi_kind = fin.t_fi_kind
--                                   AND avrkindsroot.t_avoirkind =
--                                       rsb_fiinstr.fi_avrkindsgetroot(fin.t_fi_kind, fin.t_avoirkind)
--            WHERE firest.t_sessionid = p_session_id
--     )
--     SELECT (
--           JSON_ARRAYAGG(
--               JSON_OBJECT(
--                   'ClGroupCode'              VALUE t_ClGroupCode,
--                   'DogGroupCode'             VALUE t_DogGroupCode,
--                   'ClCode'                   VALUE t_ClCode,
--                   'ClName'                   VALUE t_ClName,
--                   'NumDog'                   VALUE t_NumDog,
--                   'NumSubDog'                VALUE t_NumSubDog,
--                   'SecName'                  VALUE t_SecName,
--                   'SecRegNum'                VALUE t_SecRegNum,
--                   'ISIN'                     VALUE t_ISIN,
--                   'SecCat'                   VALUE t_SecCat,
--                   'EmiName'                  VALUE t_EmiName,
--                   'EmiCountryCode'           VALUE t_EmiCountryCode,
--                   'SecType'                  VALUE t_SecType,
--                   'VYBal'                    VALUE t_VYBal,
--                   'Quantity'                 VALUE t_Quantity,
--                   'NFI'                      VALUE t_NFI,
--                   'Nom'                      VALUE t_Nom,
--                   'CurNom'                   VALUE t_CurNom,
--                   'NomRub'                   VALUE t_NomRub,
--                   'MarketPrice'              VALUE t_MarketPrice,
--                   'CurPrice'                 VALUE t_CurPrice,
--                   'MarketPriceRub'           VALUE t_MarketPriceRub,
--                   'NKDRub'                   VALUE t_NKDRub,
--                   'Amount'                   VALUE t_Amount,
--                   'ClBalance'                VALUE t_ClBalance
--               ) order by t_ClGroupCode, t_DogGroupCode, t_VYBal
--               RETURNING CLOB
--           )
--       )
--     INTO v_json_output
--       FROM (
--           SELECT r.*
--           FROM result r
--           UNION ALL
--           -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
--           SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                  NULL, NULL, NULL, NULL, NULL
--           FROM dual
--           WHERE NOT EXISTS (SELECT 1 FROM result)
--       );
--     v_json_output := BuildSplitJsonOutput(p_trace_id_input     => p_trace_id_input,
--                                            p_json_input        => v_json_output,
--                                            p_report_date_input => p_rd_to +1,
--                                            p_report_tag        => C_REPORT_NAME_TAG,
--                                            p_items_arr_tag     => C_ITEMS_ARR_TAG,
--                                            p_template_name     => C_TEMPLATE_NAME,
--                                            p_output_file_name  => C_OUTPUT_FILE_NAME,
--                                            p_s3_file_name      => C_S3_FILE_NAME);
--     it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Расшифровка отчетной формы раздел 6 и 7 закончена', it_log.C_MSG_TYPE__DEBUG);
--     RETURN v_json_output;
--
--     EXCEPTION
--           WHEN OTHERS THEN
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--
--   END Decrypt724Part6_7;
--
--   ------------------------------------------------------------------------
--   ----- Формирование Расшифровки по разделу 8 отчетная формa 0409724 -----
--   ------------------------------------------------------------------------
--   FUNCTION Decrypt724Part8(p_trace_id_input VARCHAR2,
--                            p_rd_to          DATE,
--                            p_session_id     INTEGER
--   )
--     RETURN CLOB
--   IS
--       -- Константы
--       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := '0409724_ch8_decryption';
--       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Расшифровка_0409724_раздел_8';
--       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := '0409724_ch8_decryption';
--       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'chapter_8';
--       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'dataset';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8)  := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: другая ошибка при формировании расшифровки раздела 8';
--
--       -- Переменные
--       v_json_output           CLOB;
--
--       -- Валидация
--       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
--   BEGIN
--     it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Расшифровка отчетной формы раздел 8', it_log.C_MSG_TYPE__DEBUG);
--
--   WITH
--     result AS(
--            SELECT DISTINCT
--            pfi.t_client_groupid                                                  t_ClGroupCode
--          , pfi.t_contr_groupid                                                   t_DogGroupCode
--          , cl.t_clientcode                                                       t_ClCode
--          , cl.t_name                                                             t_ClName
--          , dog.t_number                                                          t_NumDog
--          , subDog.t_number                                                       t_NumSubDog
--          , cmp.t_mpcode                                                          t_ShortClCode
--          , pfi.t_ExtCode                                                         t_CodePFI
--          , pfi.t_ExtName                                                         t_OrgName
--          , pfi.t_PFIName                                                         t_PFIName
--          , pfi.t_Amount                                                          t_Quantity
--          , pfi.t_Dir                                                             t_Direction
--          , pfi.t_BACost                                                          t_PricePFI
--          , pfi.t_InitialCost                                                     t_SizeGuarantee
--          , pfi.t_CostPFI                                                         t_SizeActual
--          , dl.t_coderisk                                                         t_ClBalance
--            FROM d724pfi_dbt pfi
--                     JOIN d724client_dbt cl
--                          ON cl.t_sessionid = pfi.t_sessionid
--                              AND cl.t_partyid = pfi.t_partyid
--                     JOIN d724r3client_group r3
--                          ON r3.t_sessionid = pfi.t_Sessionid
--                              AND r3.t_client_groupid = pfi.t_client_groupid
--                              AND r3.t_partyid = pfi.t_partyid
--                     JOIN d724contr_dbt cr
--                          ON cr.t_sessionid = cl.t_sessionid
--                              AND cr.t_sf_id = pfi.t_contrid
--                     JOIN d724dlcontr_dbt dl
--                          ON cl.t_partyid = dl.t_partyid
--                              AND cl.t_sessionid = dl.t_sessionid
--                              AND cr.t_dlcontrid = dl.t_dlcontrid
--                     LEFT JOIN ddlcontrmp_dbt cmp
--                               ON cmp.t_sfcontrid = pfi.t_contrid
--                     LEFT JOIN (SELECT t_id, t_number FROM dsfcontr_dbt) dog
--                               ON dog.t_id = cr.t_parent_sf_id
--                     LEFT JOIN (SELECT t_id, t_number FROM dsfcontr_dbt) subDog
--                               ON subDog.t_id = pfi.t_contrid
--            WHERE pfi.t_sessionid = p_session_id
--     )
--     SELECT (
--           JSON_ARRAYAGG(
--               JSON_OBJECT(
--                   'ClGroupCode'              VALUE t_ClGroupCode,
--                   'DogGroupCode'             VALUE t_DogGroupCode,
--                   'ClCode'                   VALUE t_ClCode,
--                   'ClName'                   VALUE t_ClName,
--                   'NumDog'                   VALUE t_NumDog,
--                   'NumSubDog'                VALUE t_NumSubDog,
--                   'ShortClCode'              VALUE t_ShortClCode,
--                   'CodePFI'                  VALUE t_CodePFI,
--                   'OrgName'                  VALUE t_OrgName,
--                   'PFIName'                  VALUE t_PFIName,
--                   'Quantity'                 VALUE t_Quantity,
--                   'Direction'                VALUE t_Direction,
--                   'PricePFI'                 VALUE t_PricePFI,
--                   'SizeGuarantee'            VALUE t_SizeGuarantee,
--                   'SizeActual'               VALUE t_SizeActual,
--                   'ClBalance'                VALUE t_ClBalance
--               ) order by t_ClGroupCode,t_DogGroupCode
--               RETURNING CLOB
--           )
--       )
--     INTO v_json_output
--       FROM (
--           SELECT r.*
--           FROM result r
--           UNION ALL
--           -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
--           SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                  NULL, NULL, NULL, NULL, NULL, NULL
--           FROM dual
--           WHERE NOT EXISTS (SELECT 1 FROM result)
--       );
--
--     v_json_output := BuildSplitJsonOutput(p_trace_id_input     => p_trace_id_input,
--                                            p_json_input        => v_json_output,
--                                            p_report_date_input => p_rd_to +1,
--                                            p_report_tag        => C_REPORT_NAME_TAG,
--                                            p_items_arr_tag     => C_ITEMS_ARR_TAG,
--                                            p_template_name     => C_TEMPLATE_NAME,
--                                            p_output_file_name  => C_OUTPUT_FILE_NAME,
--                                            p_s3_file_name      => C_S3_FILE_NAME);
--     it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Расшифровка отчетной формы раздел 8 закончена', it_log.C_MSG_TYPE__DEBUG);
--     RETURN v_json_output;
--
--     EXCEPTION
--           WHEN OTHERS THEN
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--
--   END Decrypt724Part8;
--
--   ------------------------------------------------------------------------
--   ----- Формирование Расшифровки по разделу 9 отчетная формa 0409724 -----
--   ------------------------------------------------------------------------
--   FUNCTION Decrypt724Part9(p_trace_id_input VARCHAR2,
--                            p_rd_to          DATE,
--                            p_session_id     INTEGER
--   )
--     RETURN CLOB
--   IS
--       -- Константы
--       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := '0409724_ch9_decryption';
--       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Расшифровка_0409724_раздел_9';
--       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := '0409724_ch9_decryption';
--       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'chapter_9';
--       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'dataset';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8)  := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: другая ошибка при формировании расшифровки раздела 9';
--
--       -- Переменные
--       v_json_output           CLOB;
--
--       -- Валидация
--       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
--   BEGIN
--     it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Расшифровка отчетной формы раздел 9', it_log.C_MSG_TYPE__DEBUG);
--   WITH
--     result AS(
--            SELECT DISTINCT
--              ar.t_client_groupid                                                           t_ClGroupCode
--            , ar.t_contr_groupid                                                            t_DogGroupCode
--            , cl.t_clientcode                                                               t_ClCode
--            , cl.t_name                                                                     t_ClName
--            , dog.t_number                                                                  t_NumDog
--            , subDog.t_number                                                               t_NumSubDog
--            , ar.t_DealCodeTS                                                               t_OutDealCode
--            , ar.t_DealCode                                                                 t_InDealCode
--            , ar.t_Kind                                                                     t_FlagReq
--            , ar.t_SubKind                                                                  t_TypeReq
--            , ar.t_KindREPO                                                                 t_TypeRepoDeal
--            , pt.t_ShortName                                                                t_KAgentNomination
--            , t_Name1                                                                       t_KAgentLastName
--            , t_Name2                                                                       t_KAgentName
--            , t_Name3                                                                       t_KAgentSurname
--            -- IMPROVE724 вынести rsb_secur.SC_GetObjCodeOnDate  в отдельный CTE, это всего-лишь 3 выполнения функции, но в текущем варианте это 3* N-строк
--            , (CASE WHEN t_NotResident != 'X'
--                   THEN rsb_secur.SC_GetObjCodeOnDate (3, 16, pt.t_PartyId, p_rd_to )
--                   ELSE ''
--               END)                                                                         t_KAgentINN
--            , (CASE WHEN t_NotResident = 'X'
--                    THEN rsb_secur.SC_GetObjCodeOnDate (3, 62, pt.t_PartyId, p_rd_to )
--                    ELSE ''
--               END)                                                                         t_KAgentTIN
--            , (CASE WHEN t_NotResident = 'X'
--                    THEN rsb_secur.SC_GetObjCodeOnDate (3, 33, pt.t_PartyId, p_rd_to )
--                    ELSE ''
--                END)                                                                        t_KAgentNUM
--            , ar.t_Value                                                                    t_PriceMark
--            , ar.t_ValueNRur                                                                t_PriceMarkRub
--            , dl.t_coderisk                                                                 t_ClBalance
--            , (CASE WHEN p_rd_to >= to_date('01.01.2026','dd.mm.yyyy')
--                    THEN ar.t_ValueAmount
--                    ELSE null
--                END)                                                                        t_Quantity
--            FROM d724arrear_dbt ar
--                     JOIN d724client_dbt cl
--                          ON cl.t_sessionid = ar.t_sessionid
--                              AND cl.t_partyid = ar.t_partyid
--                     JOIN d724contr_dbt cr
--                          ON cr.t_sessionid = cl.t_sessionid
--                              AND cr.t_sf_id = ar.t_contrid
--                     JOIN d724dlcontr_dbt dl
--                          ON cl.t_partyid = dl.t_partyid
--                              AND cl.t_sessionid = dl.t_sessionid
--                              AND cr.t_dlcontrid = dl.t_dlcontrid
--                     JOIN d724r3client_group r3
--                          ON r3.t_sessionid = ar.t_Sessionid
--                              AND r3.t_client_groupid = ar.t_client_groupid
--                              AND r3.t_partyid = ar.t_partyid
--                     LEFT JOIN dparty_dbt pt
--                               ON pt.t_partyid = ar.t_contractorid
--                     LEFT JOIN dpersn_dbt ps
--                               ON ps.t_personid = ar.t_contractorid
--                     LEFT JOIN (SELECT t_id, t_number FROM dsfcontr_dbt) dog
--                               ON dog.t_id = cr.t_parent_sf_id
--                     LEFT JOIN (SELECT t_id, t_number FROM dsfcontr_dbt) subDog
--                               ON subDog.t_id = ar.t_contrid
--            WHERE ar.t_sessionid = p_session_id
--       )
--     SELECT (
--           JSON_ARRAYAGG(
--               JSON_OBJECT(
--                   'ClGroupCode'              VALUE t_ClGroupCode,
--                   'DogGroupCode'             VALUE t_DogGroupCode,
--                   'ClCode'                   VALUE t_ClCode,
--                   'ClName'                   VALUE t_ClName,
--                   'NumDog'                   VALUE t_NumDog,
--                   'NumSubDog'                VALUE t_NumSubDog,
--                   'OutDealCode'              VALUE t_OutDealCode,
--                   'InDealCode'               VALUE t_InDealCode,
--                   'FlagReq'                  VALUE t_FlagReq,
--                   'TypeReq'                  VALUE t_TypeReq,
--                   'TypeRepoDeal'             VALUE t_TypeRepoDeal,
--                   'KAgentNomination'         VALUE t_KAgentNomination,
--                   'KAgentLastName'           VALUE t_KAgentLastName,
--                   'KAgentName'               VALUE t_KAgentName,
--                   'KAgentSurname'            VALUE t_KAgentSurname,
--                   'KAgentINN'                VALUE t_KAgentINN,
--                   'KAgentTIN'                VALUE t_KAgentTIN,
--                   'KAgentNUM'                VALUE t_KAgentNUM,
--                   'PriceMark'                VALUE t_PriceMark,
--                   'PriceMarkRub'             VALUE t_PriceMarkRub,
--                   'ClBalance'                VALUE t_ClBalance,
--                   'Quantity'                 VALUE t_Quantity
--               ) order by t_ClGroupCode, t_DogGroupCode
--               RETURNING CLOB
--           )
--       )
--     INTO v_json_output
--       FROM (
--           SELECT r.*
--           FROM result r
--           UNION ALL
--           -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
--           SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                  NULL, NULL
--           FROM dual
--           WHERE NOT EXISTS (SELECT 1 FROM result)
--       );
--
--     v_json_output := BuildSplitJsonOutput(p_trace_id_input     => p_trace_id_input,
--                                            p_json_input        => v_json_output,
--                                            p_report_date_input => p_rd_to +1,
--                                            p_report_tag        => C_REPORT_NAME_TAG,
--                                            p_items_arr_tag     => C_ITEMS_ARR_TAG,
--                                            p_template_name     => C_TEMPLATE_NAME,
--                                            p_output_file_name  => C_OUTPUT_FILE_NAME,
--                                            p_s3_file_name      => C_S3_FILE_NAME);
--     it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Расшифровка отчетной формы раздел 9 закончена', it_log.C_MSG_TYPE__DEBUG);
--     RETURN v_json_output;
--
--     EXCEPTION
--           WHEN OTHERS THEN
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--
--   END Decrypt724Part9;
--
--   -------------------------------------------------------------------------
--   ----- Формирование Расшифровки по разделу 11 отчетная формa 0409724 -----
--   -------------------------------------------------------------------------
--   FUNCTION Decrypt724Part11(p_trace_id_input VARCHAR2,
--                             p_rd_to          DATE,
--                             p_session_id     INTEGER
--   )
--     RETURN CLOB
--   IS
--       -- Константы
--       C_TEMPLATE_NAME         CONSTANT VARCHAR2(128) := '0409724_ch11_decryption';
--       C_OUTPUT_FILE_NAME      CONSTANT VARCHAR2(128) := 'Расшифровка_0409724_раздел_11';
--       C_S3_FILE_NAME          CONSTANT VARCHAR2(128) := '0409724_ch11_decryption';
--       C_REPORT_NAME_TAG       CONSTANT VARCHAR2(128) := 'chapter_11';
--       C_ITEMS_ARR_TAG         CONSTANT VARCHAR2(128) := 'dataset';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8)  := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(128) := 'СОФР не смог сформировать отчет: другая ошибка при формировании расшифровки раздела 11';
--
--       -- Переменные
--       v_json_output           CLOB;
--
--       -- Валидация
--       v_errors_array          JSON_ARRAY_T := JSON_ARRAY_T();
--   BEGIN
--     it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Расшифровка отчетной формы раздел 11', it_log.C_MSG_TYPE__DEBUG);
--   WITH
--     result AS (
--            SELECT DISTINCT
--                   d.t_client_groupid            t_ClGroupCode
--                 , d.t_contr_groupid             t_ClDogGroupCode
--                 , d.t_clientcode                t_ClCode
--                 , d.t_name                      t_ClName
--                 , ps.t_number                   t_NumDog
--                 , s.t_number                    t_NumSubDog
--                 , cr.t_category_contr           t_ClCat
--                 , dl.t_coderisk                 t_LvlRisk
--                 , d.t_account                   t_BrokerBal
--                 , d.t_rest                      t_Rest
--                 , f.t_iso_number                t_CurCode
--                 , d.t_rest_rub                  t_RestRub
--                 , r3.t_acckind                  t_ClBalance
--            FROM d724_metall_details d
--                     JOIN dsfcontr_dbt s
--                          ON s.t_id = d.t_sf_id
--                     JOIN dsfcontr_dbt ps
--                          ON ps.t_id = d.t_parent_sf_id
--                     JOIN dfininstr_dbt f
--                          ON f.t_fiid = d.t_fiid
--                     JOIN (SELECT t_sessionid, t_acckind, t_client_groupid, t_partyid
--                           FROM d724r3client_group
--                           WHERE t_sessionid = p_session_id) r3
--                          ON r3.t_client_groupid = d.t_client_groupid
--                              AND r3.t_partyid = d.t_partyid
--                     JOIN (SELECT t_category_contr, t_dlcontrid, t_sf_id
--                           FROM d724contr_dbt
--                           WHERE t_sessionid = p_session_id) cr
--                          ON cr.t_sf_id = d.t_sf_id
--                     LEFT JOIN (SELECT t_partyid, t_dlcontrid, t_coderisk
--                                FROM d724dlcontr_dbt
--                                WHERE t_sessionid = p_session_id) dl
--                               ON d.t_partyid = dl.t_partyid
--                                   AND cr.t_dlcontrid = dl.t_dlcontrid
--            WHERE d.t_rest != 0
--     )
--     SELECT (
--           JSON_ARRAYAGG(
--               JSON_OBJECT(
--                   'ClGroupCode'              VALUE t_ClGroupCode,
--                   'DogGroupCode'             VALUE t_ClDogGroupCode,
--                   'ClCode'                   VALUE t_ClCode,
--                   'ClName'                   VALUE t_ClName,
--                   'NumDog'                   VALUE t_NumDog,
--                   'NumSubDog'                VALUE t_NumSubDog,
--                   'ClCat'                    VALUE t_ClCat,
--                   'LvlRisk'                  VALUE t_LvlRisk,
--                   'BrokerBal'                VALUE t_BrokerBal,
--                   'Rest'                     VALUE t_Rest,
--                   'CurCode'                  VALUE t_CurCode,
--                   'RestRub'                  VALUE t_RestRub,
--                   'ClBalance'                VALUE t_ClBalance
--               ) ORDER BY t_ClGroupCode, t_ClDogGroupCode, t_BrokerBal, t_NumSubDog
--               RETURNING CLOB
--           )
--       )
--     INTO v_json_output
--       FROM (
--           SELECT r.*
--           FROM result r
--           UNION ALL
--           -- Подмешиваем пустую строку на случай, если result пустой (требование Jasper для сохранения структуры JSON, иначе отчёт сломается)
--           SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
--                  NULL, NULL, NULL
--           FROM dual
--           WHERE NOT EXISTS (SELECT 1 FROM result)
--       );
--     v_json_output := BuildSplitJsonOutput(p_trace_id_input     => p_trace_id_input,
--                                            p_json_input        => v_json_output,
--                                            p_report_date_input => p_rd_to +1,
--                                            p_report_tag        => C_REPORT_NAME_TAG,
--                                            p_items_arr_tag     => C_ITEMS_ARR_TAG,
--                                            p_template_name     => C_TEMPLATE_NAME,
--                                            p_output_file_name  => C_OUTPUT_FILE_NAME,
--                                            p_s3_file_name      => C_S3_FILE_NAME);
--     it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Расшифровка отчетной формы раздел 11 закончена', it_log.C_MSG_TYPE__DEBUG);
--     RETURN v_json_output;
--
--     EXCEPTION
--           WHEN OTHERS THEN
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--
--   END Decrypt724Part11;
--
--   --------------------------------------------------------------
--   ----- Формирование Расшифровки по отчетной форме 0409724 -----
--   --------------------------------------------------------------
--
--   FUNCTION Decrypt724_RC_ReportRun(p_trace_id_input VARCHAR2,
--                                    p_json_input     CLOB,
--                                    p_is_production  CHAR DEFAULT '1' -- Флаг для режима прода
--   )
--       RETURN CLOB
--   IS
--       -- Константы - Входной JSON
--       C_IN_PERIOD_TAG         CONSTANT VARCHAR2(32) := 'period';
--       C_IN_YEAR_TAG           CONSTANT VARCHAR2(32) := 'year';
--
--       -- Константы - Ошибки
--       C_ERR_99_CODE           CONSTANT VARCHAR2(8) := 'ER_99';
--       C_ERR_99_MSG            CONSTANT VARCHAR2(64) := 'СОФР не смог сформировать отчет: другая ошибка';
--
--       -- Переменные
--       v_period                INTEGER;
--       v_year                  INTEGER;
--       v_rd_from               DATE;
--       v_rd_to                 DATE;
--
--       v_part2_CB              CLOB; -- Расшифровка по разделу 2 движению д/с
--       v_part2_DS              CLOB; -- Расшифровка по разделу 2 движению ц/б
--       v_part2_IndCode         CLOB; -- Расшифровка по разделу 2 инд. код
--       v_part2_3               CLOB; -- Расшифровка по разделу 2.3 договоры
--       v_part3                 CLOB; -- Расшифровка по разделу 3 данные о старых и новых клиентах в отчетном периоде
--       v_part4                 CLOB; -- Расшифровка по разделу 4 стоимость д/с
--       v_part6_7               CLOB; -- Расшифровка по Разделу 6-7 стоимость ц/б
--       v_part8                 CLOB; -- Расшифровка по разделу 8 стоимость ПФИ
--       v_part9                 CLOB; -- Расшифровка по разделу 9 Т0 по незавершенным сделкам
--       v_part11                CLOB; -- Расшифровка по разделу 11 стоимость металлов
--
--       v_part2_CB_len          INTEGER;
--       v_part2_DS_len          INTEGER;
--       v_part2_IndCode_len     INTEGER;
--       v_part2_3_len           INTEGER;
--       v_part3_len             INTEGER;
--       v_part4_len             INTEGER;
--       v_part6_7_len           INTEGER;
--       v_part8_len             INTEGER;
--       v_part9_len             INTEGER;
--       v_part11_len            INTEGER;
--
--       v_dest_offset           INTEGER;
--       v_json_obj              JSON_OBJECT_T;
--       v_has_args              BOOLEAN := FALSE;
--       v_session_id            INTEGER;
--       v_fill_rez              INTEGER;
--
--       v_json_output           CLOB;
--
--       v_errors_array JSON_ARRAY_T := JSON_ARRAY_T();
--
--   BEGIN
--       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Запущено построение отчёта: Расшифровка отчетной формы № 0409724', it_log.C_MSG_TYPE__DEBUG);
--
--       -- Парсим входной JSON
--       v_json_obj := JSON_OBJECT_T.parse(p_json_input);
--       v_period := v_json_obj.get_string(C_IN_PERIOD_TAG);
--       v_year := v_json_obj.get_string(C_IN_YEAR_TAG);
--       v_rd_from := CASE WHEN v_year IS NOT NULL AND v_period IS NOT NULL
--                        THEN TO_DATE(v_year || '.' || v_period, 'YYYY.MM')
--                    END;
--       v_rd_to := CASE WHEN v_rd_from IS NOT NULL
--                      THEN LAST_DAY(v_rd_from)
--                  END;
--
--       -- Если нет даты, отдаем мета-данные формы
--       v_has_args := v_rd_from IS NOT NULL;
--       IF NOT v_has_args THEN
--           it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Дата отчёта не указана, возвращаем Meta UI формы: Расшифровка отчетной формы № 0409724', it_log.C_MSG_TYPE__DEBUG);
--           RETURN BuildJsonOutput(p_body => Decrypt724ReportMetaUI());
--       END IF;
--
--       SELECT SYS_CONTEXT('USERENV','SESSIONID') into v_session_id FROM DUAL;
--
--       DBMS_LOB.CREATETEMPORARY(v_json_output, FALSE);
--       Decrypt724_FillTable(p_trace_id_input, v_rd_from, v_rd_to, v_session_id);
--       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Результат заполнения сводных таблиц для расшифровки отчетной формы 0409724: ' || v_fill_rez, it_log.C_MSG_TYPE__DEBUG);
--       -- Собираем даннные по всем разделам отдельно
--       v_part2_DS      := Decrypt724Part2_DS(p_trace_id_input, v_rd_to, v_session_id);
--       v_part2_CB      := Decrypt724Part2_CB(p_trace_id_input, v_rd_to, v_session_id);
--       v_part2_IndCode := Decrypt724part2_IndCode(p_trace_id_input, v_rd_to, v_session_id);
--       v_part2_3       := Decrypt724Part2_3(p_trace_id_input, v_rd_from, v_rd_to, v_session_id);
--       v_part3         := Decrypt724Part3(p_trace_id_input, v_rd_to, v_session_id);
--       v_part4         := Decrypt724Part4(p_trace_id_input, v_rd_to, v_session_id);
--       v_part6_7       := Decrypt724Part6_7(p_trace_id_input, v_rd_to, v_session_id);
--       v_part8         := Decrypt724Part8(p_trace_id_input, v_rd_to, v_session_id);
--       v_part9         := Decrypt724Part9(p_trace_id_input, v_rd_to, v_session_id);
--       v_part11        := Decrypt724Part11(p_trace_id_input, v_rd_to, v_session_id);
--
--       -- Записываем длину по каждому разделу
--       v_part2_DS_len      := DBMS_LOB.GETLENGTH(v_part2_DS);
--       v_part2_CB_len      := DBMS_LOB.GETLENGTH(v_part2_CB);
--       v_part2_IndCode_len := DBMS_LOB.GETLENGTH(v_part2_IndCode);
--       v_part2_3_len       := DBMS_LOB.GETLENGTH(v_part2_3);
--       v_part3_len         := DBMS_LOB.GETLENGTH(v_part3);
--       v_part4_len         := DBMS_LOB.GETLENGTH(v_part4);
--       v_part6_7_len       := DBMS_LOB.GETLENGTH(v_part6_7);
--       v_part8_len         := DBMS_LOB.GETLENGTH(v_part8);
--       v_part9_len         := DBMS_LOB.GETLENGTH(v_part9);
--       v_part11_len        := DBMS_LOB.GETLENGTH(v_part11);
--
--       -- Копируем v_part2_DS без последней скобки ']' и добавляем запятую
--       DBMS_LOB.COPY(v_json_output, v_part2_DS, v_part2_DS_len - 1, 1, 1);
--       DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');
--       v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
--
--       -- Копируем v_part2_CB без первой '[' и последней скобки ']' и добавляем запятую
--       DBMS_LOB.COPY(v_json_output, v_part2_CB, v_part2_CB_len - 2, v_dest_offset, 2);
--       DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');
--       v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
--
--       -- Копируем v_part2_IndCode без первой '[' и последней скобки ']' и добавляем запятую
--       DBMS_LOB.COPY(v_json_output, v_part2_IndCode, v_part2_IndCode_len - 2, v_dest_offset, 2);
--       DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');
--       v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
--
--       -- Копируем v_part2_3 без первой '[' и последней скобки ']' и добавляем запятую
--       DBMS_LOB.COPY(v_json_output, v_part2_3, v_part2_3_len - 2, v_dest_offset, 2);
--       DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');
--       v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
--
--       -- Копируем v_part3 без первой '[' и последней скобки ']' и добавляем запятую
--       DBMS_LOB.COPY(v_json_output, v_part3, v_part3_len - 2, v_dest_offset, 2);
--       DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');
--       v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
--
--       -- Копируем v_part4 без первой '[' и последней скобки ']' и добавляем запятую
--       DBMS_LOB.COPY(v_json_output, v_part4, v_part4_len - 2, v_dest_offset, 2);
--       DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');
--       v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
--
--       -- Копируем v_part6_7 без первой '[' и последней скобки ']' и добавляем запятую
--       DBMS_LOB.COPY(v_json_output, v_part6_7, v_part6_7_len - 2, v_dest_offset, 2);
--       DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');
--       v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
--
--       -- Копируем v_part8 без первой '[' и последней скобки ']' и добавляем запятую
--       DBMS_LOB.COPY(v_json_output, v_part8, v_part8_len - 2, v_dest_offset, 2);
--       DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');
--       v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
--
--       -- Копируем v_part9 без первой '[' и последней скобки ']' и добавляем запятую
--       DBMS_LOB.COPY(v_json_output, v_part9, v_part9_len - 2, v_dest_offset, 2);
--       DBMS_LOB.WRITEAPPEND(v_json_output, 1, ',');
--       v_dest_offset := DBMS_LOB.GETLENGTH(v_json_output) + 1;
--
--       -- Копируем v_part11 без первой '['
--       DBMS_LOB.COPY(v_json_output, v_part11, v_part11_len - 1, v_dest_offset, 2);
--
--
--       it_log.log('traceId=''' || p_trace_id_input || ''' ' || 'Построение отчёта успешно завершено: Расшифровка отчетной формы № 0409724', it_log.C_MSG_TYPE__DEBUG);
--       RETURN v_json_output;
--
--       EXCEPTION
--           WHEN OTHERS THEN
--               -- Освобождаем ресурсы
--               IF DBMS_LOB.ISTEMPORARY(v_json_output) = 1 THEN
--                   DBMS_LOB.FREETEMPORARY(v_json_output);
--               END IF;
--
--               -- Если мы сюда попали, значит произошло что-то непредвиденное
--               it_error.put_error_in_stack;
--               IF (v_errors_array.get_size() = 0) THEN
--                   v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
--                                                           C_ERR_99_MSG || ':' || SQLCODE || ' ' || SQLERRM));
--               END IF;
--
--               RETURN BuildJsonOutput(p_errors_array => v_errors_array);
--   END Decrypt724_RC_ReportRun;


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
  -- временное решение для конкретного отчета. В дальнейшем возможно стоит перегрузить функции по построению финального json
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
      C_REPORT_LOCALIZED_NAME VARCHAR2(64)  := 'Контроль за статусом и сроками предоставления отчетности в БР';
      C_SYS_TAGS              VARCHAR2(256) := '["ORACLE", "BR"]';
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
                                             'default' VALUE (SELECT JSON_ARRAYAGG(T_FORM RETURNING CLOB)
                                                              FROM dbdui_controldate_detail_dbt),
                                             'multiselect' VALUE 'true' FORMAT JSON,
                                             'items' VALUE (SELECT JSON_ARRAYAGG(
                                                                           JSON_OBJECT('name' VALUE T_LABEL, 'value' VALUE T_FORM)
                                                                           RETURNING CLOB
                                                                   )
                                                            FROM (SELECT T_FORM, T_LABEL
                                                                  FROM dbdui_controldate_detail_dbt))
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
      C_FORM_NOT_FOUND CONSTANT   VARCHAR2(60) := 'ERROR: форма не найдена в справочнике на дату <=';
      C_NO_ACTIVE_RECORD CONSTANT VARCHAR2(60) := ' SKIP: Нет актуальных записей за период ';
      v_json_output               CLOB         := C_EMPTY_JSON_ARRAY;
      v_control_date_rec          DBDUI_REPORTCONTROLDATE_DBT%ROWTYPE;
      v_postinfo_date_rec         DBDUI_REPORTPOSTINFO_DBT%ROWTYPE;
      v_work_date                 DATE;
      v_period_start              DATE; -- начало учётного периода (месяц/квартал/год)
      v_next_period_start         DATE; -- начало следующего периода ? начало отчётного окна
      v_current_date              DATE;
      v_period_offset             INTEGER;
      v_period_unit               VARCHAR2(1);
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
      -- НОВОЕ ПРАВИЛО: для формы 0409708 начиная с 01.01.2026 всегда контрольная дата 15 февраля
      -- тип - годовая
      IF p_form_name = '0409708' AND v_period_start >= DATE '2026-01-01' THEN
          v_kind :=1;
      END IF;

      -- Устанавливаем начальную дату генерации с запасом
      CASE v_kind
          WHEN 12 THEN v_current_date := TRUNC(ADD_MONTHS(p_date_begin, -1), 'MM');
          WHEN 4 THEN v_current_date := TRUNC(ADD_MONTHS(p_date_begin, -3), 'Q');
          WHEN 1 THEN v_current_date := TRUNC(ADD_MONTHS(p_date_begin, -12), 'YYYY');
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

              -- Применяем исключения ДО обычного смещения
              -- НОВОЕ ПРАВИЛО: для формы 0409708 начиная с 01.01.2026 всегда контрольная дата 15 февраля
              IF p_form_name = '0409708' AND v_period_start >= DATE '2026-01-01' THEN
                  v_next_period_start := TRUNC(v_period_start, 'YYYY');
                  v_work_date := ADD_MONTHS(TRUNC(v_period_start, 'YYYY'), 1) + 14;
              ELSIF p_form_name = '0409708'
                  AND v_kind = 4
                  AND EXTRACT(MONTH FROM v_period_start) = 10 THEN
                  -- Q4 ? всегда 15 февраля следующего года
                  v_work_date := ADD_MONTHS(TRUNC(v_period_start, 'YYYY'), 13) + 14;
                  it_log.log(v_log_prefix || ' КОСТЫЛЬ ДЛЯ 0409708 ЧЕТВЕРТОГО КВАРТАЛА ' ||
                             TO_CHAR(v_work_date, 'DD.MM.YYYY'), it_log.C_MSG_TYPE__DEBUG);
              ELSE
                  -- Обычная логика: применяем смещение
                  IF v_period_unit = 'D' THEN
                      -- v_work_date - 1, чтобы учесть 1 число месяца,  если оно рабочее. Использование календаря с ID 23 - это новое, возможно, временное требование
                      v_work_date := RSI_RSBCALENDAR.GetDateAfterWorkDay(v_work_date - 1, v_period_offset, 23);
                  ELSIF v_period_unit = 'M' THEN
                      v_work_date := ADD_MONTHS(v_work_date, v_period_offset);
                  ELSE
                      RAISE_APPLICATION_ERROR(-20001, 'Период ' || v_period_unit || ' пока не поддерживается');
                  END IF;
              END IF;

              -- === ШАГ 4: Проверяем ПЕРЕСЕЧЕНИЕ отчётного окна с запрашиваемым периодом ===
              -- Отчётное окно: [v_next_period_start, v_work_date]
              -- Запрашиваемый период: [p_date_begin, p_date_end]
              IF p_date_begin <= v_work_date AND v_next_period_start <= p_date_end THEN
                  -- Попадает: есть пересечение
                  BEGIN
                      SELECT *
                      INTO v_postinfo_date_rec
                      FROM DBDUI_REPORTPOSTINFO_DBT
                      WHERE T_FORM = p_form_name
                        AND T_LIMITDATE = v_work_date;

                      v_result_array.append(
                              JSON_OBJECT_T(
                                      JSON_OBJECT(
                                              'report_form' VALUE v_form_desc,
                                              'lim_date' VALUE TO_CHAR(v_postinfo_date_rec.T_LIMITDATE, 'DD.MM.YYYY'),
                                              'send_day' VALUE TO_CHAR(v_postinfo_date_rec.T_SENDDAY, 'DD.MM.YYYY'),
                                              'reg_day' VALUE TO_CHAR(v_postinfo_date_rec.T_REGDATE, 'DD.MM.YYYY'),
                                              'status' VALUE v_postinfo_date_rec.T_STATUS,
                                              'mess' VALUE TO_CHAR(v_postinfo_date_rec.T_MESSAGE),
                                              'date' VALUE TO_CHAR(v_postinfo_date_rec.T_ADDTIME, 'DD.MM.YYYY'),
                                              'date_end' VALUE TO_CHAR(p_date_end, 'DD.MM.YYYY')
                                      )
                              )
                      );

                  EXCEPTION
                      WHEN NO_DATA_FOUND THEN
                          INSERT INTO DBDUI_REPORTPOSTINFO_DBT (T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS,
                                                                T_MESSAGE,
                                                                T_ADDTIME)
                          VALUES (p_form_name, v_work_date, NULL, NULL, NULL, NULL, SYSTIMESTAMP);
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
                  END;
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
      C_OUTPUT_FILE_NAME_PRE CONSTANT VARCHAR2(128) := 'Контроль_сроков_предоставления_отчетности_БР';
      C_S3_FILE_NAME CONSTANT         VARCHAR2(128) := 'control_dates_report';
      C_REPORT_NAME_TAG CONSTANT      VARCHAR2(128) := 'GetLmitDayReport';
      C_ITEMS_ARR_TAG CONSTANT        VARCHAR2(128) := 'LimitDay_info';
      C_IN_BEGIN_DATE_TAG CONSTANT    VARCHAR2(32)  := 'beginDate';
      C_IN_END_DATE_TAG CONSTANT      VARCHAR2(32)  := 'endDate';
      C_IN_REPORT_NAME_TAG    CONSTANT VARCHAR2(32)  := 'reportName';
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
      v_json_clob                     CLOB          := C_EMPTY_JSON_ARRAY;
  BEGIN
      IF p_json_input IS NULL OR p_json_input = '{}' OR p_json_input = '[]' THEN
          RETURN BuildJsonOutput(p_body => ControlDateMetaUI());
      END IF;
      v_json_obj := JSON_OBJECT_T.parse(p_json_input);
      v_date_begin := TO_DATE(v_json_obj.get_string(C_IN_BEGIN_DATE_TAG), C_IN_DATE_FORMAT);
      v_date_end := TO_DATE(v_json_obj.get_string(C_IN_END_DATE_TAG), C_IN_DATE_FORMAT);

      v_report_name_list := v_json_obj.get_Array(C_IN_REPORT_NAME_TAG);

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
                  it_error.put_error_in_stack;
                  RAISE_APPLICATION_ERROR(-20001, 'traceId=''' || p_trace_id_input ||
                                                  ''' Ошибка поиска формы отчета в справочнике: ' || SQLERRM);
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
                      it_error.put_error_in_stack;
                      RAISE_APPLICATION_ERROR(-20001,
                                              'traceId=''' || p_trace_id_input || ''' ' || 'Ошибка обработки: ' ||
                                              SQLERRM);
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

  /**************************************************************************************************\
  [Начало блока] BIQ-34452(avt) Добавление квитанции к отчету контроля за статусами и сроками предоставления отчетности в БР
  Изменения:
  --------------------------------------------------------------------------------------------------------------
  Дата        Автор            Jira                                    Описание
  ----------  ---------------  --------------------------------------  -----------------------------------------
  19.03.2026  Борисов Т.Ю.     BIQ-34452                               Создание

  \**************************************************************************************************/

  /**************************************************************************************************\
    -- UI
  */
  FUNCTION AddReceiptInfoReportMetaUi
      RETURN CLOB
      IS
      C_ROLES                 VARCHAR2(256) := '["dkk_staff"]';
      C_REPORT_LOCALIZED_NAME VARCHAR2(256)  := 'Добавление квитанции к отчету контроля за статусами и сроками предоставления отчетности в БР';
      C_SYS_TAGS              VARCHAR2(256) := '["ORACLE", "BR"]';
      v_meta_ui               CLOB;
  BEGIN

      SELECT JSON_OBJECT(
                     C_META_UI_TAG__ROLES   VALUE C_ROLES FORMAT JSON,
                     C_META_UI_TAG__LABEL   VALUE C_REPORT_LOCALIZED_NAME,
                     C_META_UI_TAG__SYSTAGS VALUE C_SYS_TAGS FORMAT JSON,
                     C_META_UI_TAG__FORM    VALUE JSON_ARRAY(
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

  /**************************************************************************************************\
        [Начало] Парсинг XML из входного JSON
        Описание: Извлекает и валидирует XML-квитанцию из поля "ReceiptFile" входного JSON
        Параметры:
          p_json_input - Входной JSON с полем "ReceiptFile" (строка или массив из одной строки)
        Возвращает: Валидированный XML-контент без декларации <?xml ...?>
        Исключения:
          -20001 - Ошибка валидации ReceiptFile: пустой вход или некорректный формат
          -20002 - Содержимое квитанции отсутствует
      \**************************************************************************************************/
  FUNCTION ParseReceiptXml(
      p_json_input CLOB
  ) RETURN CLOB
      IS
      C_EMPTY_RECEPT CONSTANT VARCHAR2(50)    :=  'Содержимое квитанции отсутствует';
      C_UNKNOWN_FORMAT CONSTANT VARCHAR2(150) := 'ReceiptFile имеет неверный формат: ожидается строка или массив из одной строки';
      C_RECEIPT_EMPTY  CONSTANT VARCHAR2(50)  := 'ReceiptFile содержит пустое значение';
      v_xml_content   CLOB;
      v_json_obj      JSON_OBJECT_T;
      v_receipt_value JSON_ELEMENT_T;
  BEGIN
      IF p_json_input IS NULL OR p_json_input = '{}' OR p_json_input = '[]' THEN
          RAISE_APPLICATION_ERROR(-20002, C_EMPTY_RECEPT);
      END IF;

      v_json_obj := JSON_OBJECT_T.parse(p_json_input);
      v_receipt_value := v_json_obj.get('ReceiptFile');

      IF v_receipt_value.is_array THEN
          v_xml_content := JSON_ARRAY_T(v_receipt_value).get_string(0);
      ELSIF v_receipt_value.is_string THEN
          v_xml_content := v_receipt_value.to_string();
      ELSE
          RAISE_APPLICATION_ERROR(-20001,
                                  C_UNKNOWN_FORMAT);
      END IF;

      IF v_xml_content IS NULL THEN
          RAISE_APPLICATION_ERROR(-20001, C_RECEIPT_EMPTY);
      END IF;

      -- Удаляем декларацию XML
      v_xml_content := REGEXP_REPLACE(v_xml_content, '^\s*<\?xml[^>]*>\s*', '', 1, 1, 'm');
      RETURN v_xml_content;
  EXCEPTION
      WHEN OTHERS THEN
          RAISE_APPLICATION_ERROR(-20001, 'Ошибка при парсинге ReceiptFile: ' || SQLERRM);
  END ParseReceiptXml;

/**************************************************************************************************\
  [Начало] Определение типа квитанции
  Описание: Определяет тип квитанции по локальному имени корневого элемента XML
  Параметры:
    p_xml - XML-документ для анализа
  Возвращает: Тип квитанции: 'SOAP', 'STATUS', 'IES1', 'IES2'
  Исключения:
    -20001 - Неизвестный формат квитанции
\**************************************************************************************************/
  FUNCTION DetectReceiptType(
      p_xml XMLTYPE
  ) RETURN VARCHAR2
      IS
      C_UNKNOWN_FORMAT CONSTANT VARCHAR2(50) := 'Неизвестный формат квитанции';
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

/**************************************************************************************************\
  [Начало] Формирование JSON-ответа для квитанции
  Описание: Формирует ответ в требуемом формате из данных строки таблицы
  Параметры:
    p_form_code  - Код формы (T_FORM)
    p_limit_date - Контрольная дата (T_LIMITDATE)
    p_send_day   - Дата отправки (T_SENDDAY)
    p_reg_day    - Дата регистрации (T_REGDATE)
    p_status     - Статус (T_STATUS)
    p_message    - Сообщение (T_MESSAGE)
  Возвращает: JSON-объект в формате:
    {
      "report_form": "...",
      "lim_date": "DD.MM.YYYY",
      "send_day": "DD.MM.YYYY",
      "reg_day": "DD.MM.YYYY",
      "status": "...",
      "mess": "...",
      "date": "",
      "date_end": ""
    }
\**************************************************************************************************/
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
      v_form_name VARCHAR2(100);
  BEGIN
      SELECT T_LABEL into v_form_name
      FROM dbdui_controldate_detail_dbt where T_FORM = p_form_code;
      SELECT JSON_OBJECT(
                     'report_form' VALUE v_form_name,
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

/**************************************************************************************************\
  [Начало] Обработка квитанции типа ИЭС1
  Описание: Обрабатывает входящую ИЭС1, обновляя существующую запись-заглушку или создавая новую
  Логика обновления: только если T_STATUS IS NULL AND (T_MESSAGE IS NULL OR пустой)
  Параметры:
    p_xml          - XML-документ ИЭС1
    p_result_array - Массив для добавления результата обработки
  Исключения:
    -20001 - Ошибка при обработке ИЭС1
    -00001 - Нарушение уникального ограничения (квитанция уже загружена)
\**************************************************************************************************/
  PROCEDURE ProcessIes1Receipt(
      p_xml XMLTYPE,
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
      v_existing_count NUMBER := 0;
      v_status         VARCHAR2(512);
  BEGIN
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

      -- Преобразование временных меток
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

      -- Поиск записи-заглушки
      SELECT COUNT(*)
      INTO v_existing_count
      FROM DBDUI_REPORTPOSTINFO_DBT
      WHERE T_FORM = v_form_code
        AND T_LIMITDATE = v_limit_date_db
        AND T_STATUS IS NULL
        AND (T_MESSAGE IS NULL OR DBMS_LOB.GETLENGTH(T_MESSAGE) = 0);

      -- Обновление или вставка
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
          END;
      END IF;

      -- Формирование ответа
      DECLARE
          v_json_clob CLOB;
      BEGIN
          v_json_clob :=
                  BuildReceiptJson(v_form_code, v_limit_date_db, v_send_time, v_reg_time, v_status, v_message_detail);
          p_result_array.append(JSON_OBJECT_T.parse(v_json_clob));
      END;
  EXCEPTION
      WHEN OTHERS THEN
          RAISE_APPLICATION_ERROR(-20001, 'Ошибка при обработке ИЭС1: ' || SQLERRM);
  END ProcessIes1Receipt;

/**************************************************************************************************\
  [Начало] Обработка квитанции типа ИЭС2
  Описание: Обрабатывает входящую ИЭС2, обновляя существующую запись-заглушку или создавая новую
  Логика обновления: только если T_STATUS IS NULL AND (T_MESSAGE IS NULL OR пустой)
  Параметры:
    p_xml          - XML-документ ИЭС2
    p_result_array - Массив для добавления результата обработки
  Исключения:
    -20001 - Ошибка при обработке ИЭС2
    -00001 - Нарушение уникального ограничения (квитанция уже загружена)
\**************************************************************************************************/
  PROCEDURE ProcessIes2Receipt(
      p_xml XMLTYPE,
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
      v_existing_count NUMBER := 0;
      v_status         VARCHAR2(512);
  BEGIN
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
               LEFT JOIN XMLTABLE(
              '/*[local-name()="ИЭС2"]/*[local-name()="ДанныеОЭС"]/*[local-name()="ПротоколКонтроля"]/*[local-name()="Сообщение"]'
              PASSING p_xml
              COLUMNS msg VARCHAR2(4000) PATH '.'
                          ) m on 1=1
      GROUP BY r.form_code, r.send_time, r.reg_time, r.limit_time, r.result_control;

      -- Преобразование временных меток
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

      -- Поиск записи-заглушки
      SELECT COUNT(*)
      INTO v_existing_count
      FROM DBDUI_REPORTPOSTINFO_DBT
      WHERE T_FORM = v_form_code
        AND T_LIMITDATE = v_limit_date_db
        AND T_STATUS IS NULL
        AND (T_MESSAGE IS NULL OR DBMS_LOB.GETLENGTH(T_MESSAGE) = 0);

      -- Обновление или вставка
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
          END;
      END IF;

      -- Формирование ответа
      DECLARE
          v_json_clob CLOB;
      BEGIN
          v_json_clob :=
                  BuildReceiptJson(v_form_code, v_limit_date_db, v_send_time, v_reg_time, v_status, v_message_detail);
          p_result_array.append(JSON_OBJECT_T.parse(v_json_clob));
      END;
  EXCEPTION
      WHEN OTHERS THEN
          RAISE_APPLICATION_ERROR(-20001, 'Ошибка при обработке ИЭС2: ' || SQLERRM);
  END ProcessIes2Receipt;

/**************************************************************************************************\
  [Начало] Обработка квитанции типа Status
  Описание: Обрабатывает квитанцию статуса от БР, обновляя или создавая запись для admission_procedure
  Логика: обновление только записей со статусом NULL, иначе - вставка новой записи
  Параметры:
    p_xml          - XML-документ Status
    p_result_array - Массив для добавления результата обработки
  Исключения:
    -20001 - Ошибка при обработке квитанции Status
    -00001 - Нарушение уникального ограничения (квитанция уже загружена)
\**************************************************************************************************/
  PROCEDURE ProcessStatusReceipt(
      p_xml XMLTYPE,
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
  BEGIN
      SELECT x.regNum, x.status, TO_TIMESTAMP_TZ(x.dateTime, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM')
      INTO v_reg_num, v_result_text, v_date_time
      FROM XMLTABLE(
                   XMLNAMESPACES ('http://www.cbr.ru/igr/' AS "igr"),
                   '/igr:Status' PASSING p_xml
                   COLUMNS
                       regNum VARCHAR2(64) PATH 'igr:regNum',
                       status VARCHAR2(64) PATH 'igr:status',
                       dateTime VARCHAR2(32) PATH 'igr:dateTime'
           ) x;

      -- Перевод статусов на русский
      v_status := CASE LOWER(v_result_text)
                      WHEN 'delivered' THEN 'загружено'
                      WHEN 'registered' THEN 'зарегистрировано'
                      WHEN 'processing' THEN 'принято в обработку'
                      ELSE v_result_text
          END;

      v_limit_calc := TRUNC(v_date_time);

      -- Обновление записи со статусом NULL
      UPDATE DBDUI_REPORTPOSTINFO_DBT
      SET T_REGDATE = CAST(v_date_time AS DATE),
          T_STATUS  = v_status
      WHERE T_FORM = 'admission_procedure'
        AND T_LIMITDATE = v_limit_calc
        AND T_STATUS IS NULL
      RETURNING ROWID INTO v_rowid;

      IF SQL%ROWCOUNT > 0 THEN
          -- Получаем данные обновлённой записи
          SELECT T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE
          INTO v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message
          FROM DBDUI_REPORTPOSTINFO_DBT
          WHERE ROWID = v_rowid;
      ELSE
          -- Вставка новой записи
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

              -- Получаем данные вставленной записи
              SELECT T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE
              INTO v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message
              FROM DBDUI_REPORTPOSTINFO_DBT
              WHERE ROWID = v_rowid;
          END;
      END IF;

      -- Формирование ответа
      DECLARE
          v_json_clob CLOB;
      BEGIN
          v_json_clob := BuildReceiptJson(v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message);
          p_result_array.append(JSON_OBJECT_T.parse(v_json_clob));
      END;
  EXCEPTION
      WHEN OTHERS THEN
          RAISE_APPLICATION_ERROR(-20001, 'Ошибка при обработке квитанции Status: ' || SQLERRM);
  END ProcessStatusReceipt;

/**************************************************************************************************\
  [Начало] Обработка квитанции типа SOAP
  Описание: Обрабатывает квитанцию SOAP от БР, обновляя или создавая запись для admission_procedure
  Логика: обновление только записей со статусом NULL, иначе - вставка новой записи
  Параметры:
    p_xml          - XML-документ SOAP
    p_result_array - Массив для добавления результата обработки
  Исключения:
    -20001 - Ошибка при обработке квитанции SOAP
    -00001 - Нарушение уникального ограничения (квитанция уже загружена)
\**************************************************************************************************/
  PROCEDURE ProcessSoapReceipt(
      p_xml XMLTYPE,
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
  BEGIN
      SELECT x.CorrelationMessageID, a.ResultText, TO_TIMESTAMP_TZ(x.CreateTime, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM')
      INTO v_correlation_id, v_result_text, v_create_time
      FROM XMLTABLE(
                   XMLNAMESPACES (
                       'http://www.w3.org/2003/05/soap-envelope' AS "env",
                       'urn:cbr-ru:msg:props:v1.3' AS "props"
                       ),
                   '/env:Envelope/env:Header/props:MessageInfo' PASSING p_xml
                   COLUMNS
                       CorrelationMessageID VARCHAR2(64) PATH 'props:CorrelationMessageID',
                       CreateTime VARCHAR2(32) PATH 'props:CreateTime'
           ) x
               CROSS JOIN XMLTABLE(
              XMLNAMESPACES ('urn:cbr-ru:msg:props:v1.3' AS "props"),
              '/props:AcknowledgementInfo' PASSING p_xml
              COLUMNS ResultText VARCHAR2(64) PATH 'props:ResultText'
                          ) a;

      -- Перевод статусов на русский
      v_status := CASE LOWER(v_result_text)
                      WHEN 'delivered' THEN 'загружено'
                      WHEN 'registered' THEN 'зарегистрировано'
                      WHEN 'processing' THEN 'принято в обработку'
                      ELSE v_result_text
          END;

      v_limit_calc := TRUNC(v_create_time);

      -- Обновление записи со статусом NULL
      UPDATE DBDUI_REPORTPOSTINFO_DBT
      SET T_SENDDAY = CAST(v_create_time AS DATE),
          T_STATUS  = v_status
      WHERE T_FORM = 'admission_procedure'
        AND T_LIMITDATE = v_limit_calc
        AND T_STATUS IS NULL
      RETURNING ROWID INTO v_rowid;

      IF SQL%ROWCOUNT > 0 THEN
          -- Получаем данные обновлённой записи
          SELECT T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE
          INTO v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message
          FROM DBDUI_REPORTPOSTINFO_DBT
          WHERE ROWID = v_rowid;
      ELSE
          -- Вставка новой записи
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

              -- Получаем данные вставленной записи
              SELECT T_FORM, T_LIMITDATE, T_SENDDAY, T_REGDATE, T_STATUS, T_MESSAGE
              INTO v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message
              FROM DBDUI_REPORTPOSTINFO_DBT
              WHERE ROWID = v_rowid;
          END;
      END IF;

      -- Формирование ответа
      DECLARE
          v_json_clob CLOB;
      BEGIN
          v_json_clob := BuildReceiptJson(v_form_code, v_limit_date, v_send_day, v_reg_day, v_status, v_message);
          p_result_array.append(JSON_OBJECT_T.parse(v_json_clob));
      END;
  EXCEPTION
      WHEN OTHERS THEN
          RAISE_APPLICATION_ERROR(-20001, 'Ошибка при обработке квитанции SOAP: ' || SQLERRM);
  END ProcessSoapReceipt;

/**************************************************************************************************\
  [Начало] Основная функция обработки квитанций
  Описание: Обрабатывает входящие квитанции и исходные ЭС от БР согласно таблице кейсов
  Параметры:
    p_trace_id_input - Идентификатор трассировки для логирования
    p_json_input     - Входной JSON с полем "ReceiptFile", содержащим XML-квитанцию
    p_is_production  - Флаг production-режима (не используется, зарезервировано)
  Возвращает: JSON-ответ в формате SOFR с результатом обработки
  Исключения:
    Возвращает ошибки в формате JSON через BuildJsonOutput (не использует RAISE_APPLICATION_ERROR)
\**************************************************************************************************/
  FUNCTION AddReceiptInfo_RC_ReportRun(
      p_trace_id_input VARCHAR2,
      p_json_input CLOB,
      p_is_production CHAR DEFAULT '1'
  ) RETURN CLOB
      IS
      PRAGMA AUTONOMOUS_TRANSACTION;
      C_TEMPLATE_NAME CONSTANT        VARCHAR2(128) := 'limit_day_report';
      C_S3_FILE_NAME CONSTANT         VARCHAR2(128) := 'control_dates_report';
      C_REPORT_NAME_TAG CONSTANT      VARCHAR2(128) := 'GetLmitDayReport';
      C_ITEMS_ARR_TAG CONSTANT        VARCHAR2(128) := 'LimitDay_info';
      C_OUTPUT_FILE_NAME_PRE CONSTANT VARCHAR2(128) := 'Квитанции_БР';
      C_ERR_99_CODE CONSTANT          VARCHAR2(8)   := 'ER_99';
      C_ERR_99_MSG CONSTANT           VARCHAR2(64)  := 'СОФР не смог обработать квитанцию: ошибка';
      v_xml_content                   CLOB;
      v_xml                           XMLTYPE;
      v_result_array                  JSON_ARRAY_T  := JSON_ARRAY_T();
      v_json_output                   CLOB;
      v_errors_array                  JSON_ARRAY_T  := JSON_ARRAY_T();
      v_receipt_type                  VARCHAR2(10);
  BEGIN
      -- Обработка пустого входа
      IF p_json_input IS NULL OR p_json_input = '{}' OR p_json_input = '[]' THEN
          RETURN BuildJsonOutput(p_body => AddReceiptInfoReportMetaUi());
      END IF;

      -- Парсинг и валидация входного XML
      BEGIN
          v_xml_content := ParseReceiptXml(p_json_input);
          v_xml := XMLTYPE(v_xml_content);
      EXCEPTION
          WHEN OTHERS THEN
              v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                      'Некорректный XML: ' || SQLERRM));
              RETURN BuildJsonOutput(p_errors_array => v_errors_array);
      END;

      -- Определение типа квитанции
      BEGIN
          v_receipt_type := DetectReceiptType(v_xml);
      EXCEPTION
          WHEN OTHERS THEN
              v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                      'Неизвестный формат квитанции: ' || SQLERRM));
              RETURN BuildJsonOutput(p_errors_array => v_errors_array);
      END;

      -- Обработка по типу
      BEGIN
          CASE v_receipt_type
              WHEN 'SOAP' THEN ProcessSoapReceipt(v_xml, v_result_array);
              WHEN 'STATUS' THEN ProcessStatusReceipt(v_xml, v_result_array);
              WHEN 'IES1' THEN ProcessIes1Receipt(v_xml, v_result_array);
              WHEN 'IES2' THEN ProcessIes2Receipt(v_xml, v_result_array);
              END CASE;
      EXCEPTION
          WHEN OTHERS THEN
              v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE,
                                                      'Ошибка при обработке квитанции: ' || SQLERRM));
              RETURN BuildJsonOutput(p_errors_array => v_errors_array);
      END;

      COMMIT;

      -- Формирование финального результата
      v_json_output := v_result_array.to_clob();
      v_json_output := BuildSplitJsonOutput(
              p_trace_id_input => p_trace_id_input,
              p_json_input => v_json_output,
              p_report_date_input => SYSDATE,
              p_report_tag => C_REPORT_NAME_TAG,
              p_items_arr_tag => C_ITEMS_ARR_TAG,
              p_template_name => C_TEMPLATE_NAME,
              p_output_file_name => C_OUTPUT_FILE_NAME_PRE,
              p_s3_file_name => C_S3_FILE_NAME
                       );

      RETURN v_json_output;

  EXCEPTION
      WHEN OTHERS THEN
          ROLLBACK;
          v_errors_array.append(GetErrorObjAndLog(p_trace_id_input, C_ERR_99_CODE, C_ERR_99_MSG || ': ' || SQLERRM));
          RETURN BuildJsonOutput(p_errors_array => v_errors_array);
  END AddReceiptInfo_RC_ReportRun;
  /**************************************************************************************************\
  [Конец блока] BIQ-34452(avt) Добавление квитанции к отчету контроля за статусами и сроками предоставления отчетности в БР
  \**************************************************************************************************/

END IT_CheckLimitReport;
/
