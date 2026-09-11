WITH PROVEEDOR_POR_FACTURA AS (
    SELECT
         AILA.INVOICE_ID
        ,AILA.MERCHANT_NAME
        ,ROW_NUMBER() OVER (
            PARTITION BY AILA.INVOICE_ID
            ORDER BY AILA.AMOUNT DESC NULLS LAST
        ) AS RN
    FROM 
        AP_INVOICE_LINES_ALL                            AILA
    WHERE 
        AILA.MERCHANT_NAME IS NOT NULL
)
,CUENTA_CONTABLE_POR_GASTO AS (
    SELECT
         EED.EXPENSE_ID
        ,EED.CODE_COMBINATION_ID
        ,ROW_NUMBER() OVER (
            PARTITION BY EED.EXPENSE_ID
            ORDER BY EED.REIMBURSABLE_AMOUNT DESC NULLS LAST
        ) AS RN
    FROM 
        EXM_EXPENSE_DISTS                               EED
)
,ADELANTOS_POR_INFORME AS (
    SELECT
         ECAA.EXPENSE_REPORT_ID
        ,SUM(ECAA.AMOUNT) AS                            TOTAL_ADELANTO_APLICADO
    FROM 
        EXM_CASH_ADV_APPLICATIONS ECAA
    GROUP BY 
        ECAA.EXPENSE_REPORT_ID
)
,LINEAS_PADRE_EXCLUIR AS (
    SELECT DISTINCT ITEMIZATION_PARENT_EXPENSE_ID       EXPENSE_ID_PADRE
    FROM EXM_EXPENSES
    WHERE ITEMIZATION_PARENT_EXPENSE_ID IS NOT NULL
      AND ITEMIZATION_PARENT_EXPENSE_ID != -1
    UNION
    SELECT DISTINCT MERGED_PARENT_EXPENSE_ID            EXPENSE_ID_PADRE
    FROM EXM_EXPENSES
    WHERE MERGED_PARENT_EXPENSE_ID IS NOT NULL
      AND MERGED_PARENT_EXPENSE_ID != -1
)
-- NUEVO: distribuciones contables de AP (una fila por invoice + línea)
,DISTRIBUCIONES_AP AS (
    SELECT
         AID.INVOICE_ID
        ,AID.INVOICE_LINE_NUMBER
        ,AID.DIST_CODE_COMBINATION_ID
        ,GCC.CONCATENATED_SEGMENTS                     COMBINACION_CONTABLE_AP_TXT
    FROM
         AP_INVOICE_DISTRIBUTIONS_ALL                  AID
        ,GL_CODE_COMBINATIONS                          GCC
    WHERE
         AID.DIST_CODE_COMBINATION_ID = GCC.CODE_COMBINATION_ID(+)
)
,BASE_DATOS AS (
    SELECT
         HAOUV.NAME                                     UNIDAD_NEGOCIO                -- #2
        ,XEP.NAME                                       RAZON_SOCIAL                  -- #1
        ,PPNF.FULL_NAME                                 NOMBRE_DEL_EMPLEADO           -- #3
        ,EER.EXPENSE_REPORT_NUM                         NUM_INFORME_DE_GASTOS         -- #4
        ,EER.EXPENSE_STATUS_CODE                        ESTADO_DEL_INFORME            -- #5
        -- CAMPO #6: Fecha de Creación = Fecha de aprobación final del informe
        ,TO_CHAR(EER.FINAL_APPROVAL_DATE, 'DD/MM/YYYY') FECHA_DE_CREACION             -- #6 (CORREGIDO)
        ,ROW_NUMBER() OVER (
            PARTITION BY EE.EXPENSE_REPORT_ID 
            ORDER BY EE.EXPENSE_ID
        )                                               LINEA_DE_GASTO                -- #7
        ,TO_CHAR(EE.RECEIPT_DATE, 'DD/MM/YYYY')         FECHA_DEL_GASTO_LINEA         -- #8
        ,ET.NAME                                        TIPO_DE_GASTO                 -- #9
        ,EE.DESCRIPTION                                 DESCRIPCION_DEL_GASTO         -- #10
        ,NVL(PPF.MERCHANT_NAME, 'PROVEEDOR NO IDENTIFICADO') 
                                                        NOMBRE_COMERCIANTE_PROVEEDOR_EXP  -- #11
        ,AIA.INVOICE_NUM                                NUMERO_DE_FACTURA_AP          -- #12
        ,PS.VENDOR_NAME                                 PROVEEDOR_AP                  -- #13
        ,AIA.APPROVAL_STATUS                            ESTADO_FACTURA_AP             -- #14
        ,TO_CHAR(AIA.INVOICE_DATE, 'DD/MM/YYYY')        FECHA_FACTURA_AP              -- #15
        ,TO_CHAR(AIA.GL_DATE, 'DD/MM/YYYY')             FECHA_CONTABLE_AP             -- #16
        ,EER.REIMBURSEMENT_CURRENCY_CODE                MONEDA_INTRODUCIDA_EXP        -- #17
        ,EER.EXPENSE_REPORT_TOTAL                       IMPORTE_EXP_MONEDA_INTRODUCIDA-- #18
        ,AIA.INVOICE_AMOUNT                             IMPORTE_AP_MONEDA_INTRODUCIDA -- #19
        ,(EER.EXPENSE_REPORT_TOTAL - NVL(AIA.INVOICE_AMOUNT,0)) 
                                                        DIFERENCIA_MONEDA_INTRODUCIDA -- #20
        ,EE.EXCHANGE_RATE                               TIPO_DE_CAMBIO                -- #21
        ,GL.CURRENCY_CODE                               MONEDA_FUNCIONAL              -- #22
        -- Importe EXP en moneda funcional (ajustar según tu configuración)
        ,EER.EXPENSE_REPORT_TOTAL * NVL(EE.EXCHANGE_RATE,1) 
                                                        IMPORTE_EXP_MONEDA_FUNCIONAL  -- #23
        -- Importe AP en moneda funcional
        ,AIA.INVOICE_AMOUNT * NVL(AIA.EXCHANGE_RATE,1)  IMPORTE_AP_MONEDA_FUNCIONAL   -- #24
        -- Diferencia en moneda funcional
        ,(EER.EXPENSE_REPORT_TOTAL * NVL(EE.EXCHANGE_RATE,1) 
          - AIA.INVOICE_AMOUNT * NVL(AIA.EXCHANGE_RATE,1)) 
                                                        DIFERENCIA_MONEDA_FUNCIONAL   -- #25
        -- Impuestos (pendientes de mapeo físico completo)
        ,NULL                                           CODIGO_DE_IMPUESTO_EXP        -- #26
        ,NVL(AIA.TOTAL_TAX_AMOUNT,0)                    IMPORTE_IMPUESTO_AP           -- #29
        ,NULL                                           CODIGO_DE_IMPUESTO_AP         -- #28
        ,NVL(AIA.TOTAL_TAX_AMOUNT,0)                    IMPORTE_IMPUESTO_EXP          -- #27
        ,NVL(AIA.TOTAL_TAX_AMOUNT,0) - NVL(AIA.TOTAL_TAX_AMOUNT,0) 
                                                        DIFERENCIA_IMPUESTO           -- #30
        -- #31 Combinación contable EXP
        ,CCPG.CODE_COMBINATION_ID                       COMBINACION_CONTABLE_EXP_ID
        -- #32 Combinación contable AP (texto legible)
        ,DAP.COMBINACION_CONTABLE_AP_TXT                COMBINACION_CONTABLE_AP       -- #32
        -- #33 Diferencia Cuenta Contable
        ,CASE 
            WHEN CCPG.CODE_COMBINATION_ID IS NOT NULL 
             AND DAP.DIST_CODE_COMBINATION_ID IS NOT NULL 
             AND CCPG.CODE_COMBINATION_ID != DAP.DIST_CODE_COMBINATION_ID 
            THEN 'DIFERENTE'
            WHEN CCPG.CODE_COMBINATION_ID IS NOT NULL 
             AND DAP.DIST_CODE_COMBINATION_ID IS NULL 
            THEN 'SIN_CUENTA_AP'
            WHEN CCPG.CODE_COMBINATION_ID IS NULL 
             AND DAP.DIST_CODE_COMBINATION_ID IS NOT NULL 
            THEN 'SIN_CUENTA_EXP'
            ELSE 'IGUAL'
         END                                            DIFERENCIA_CUENTA_CONTABLE    -- #33
        -- Columnas adicionales que ya tenías
        ,EER.REIMBURSEMENT_CURRENCY_CODE                MONEDA_INTRODUCIDA
        ,EER.EXPENSE_REPORT_TOTAL                       MONTO_EXPENSES
        ,GL.CURRENCY_CODE                               MONEDA_FUNCIONAL_LEDGER
        ,AIA.INVOICE_NUM                                DOCUMENTO_REF_AP
        ,AIA.APPROVAL_STATUS                            ESTADO_AP
        ,AIA.INVOICE_AMOUNT                             MONTO_AP
        ,NVL(AIA.AMOUNT_PAID, 0)                        IMPORTE_PAGADO_AP
        ,(AIA.INVOICE_AMOUNT - NVL(AIA.AMOUNT_PAID, 0)) IMPORTE_PENDIENTE_AP
        ,AIA.EXCHANGE_RATE                              TIPO_CAMBIO_AP
        ,NVL(AIA.TOTAL_TAX_AMOUNT, 0)                   IMPUESTO_AP
        ,(EER.EXPENSE_REPORT_TOTAL - NVL(AIA.INVOICE_AMOUNT,0)) DIFERENCIA_VALOR
        ,CASE
             WHEN EER.EXPENSE_STATUS_CODE LIKE '%REJECT%' OR EER.EXPENSE_STATUS_CODE = 'RETURNED'
                  THEN 'OBSERVADO'
             WHEN AIA.INVOICE_NUM IS NOT NULL 
                  AND NVL(AIA.AMOUNT_PAID, 0) = 0 
                  AND ABS(EER.EXPENSE_REPORT_TOTAL - NVL(AIA.INVOICE_AMOUNT,0)) > 0.01 
                  THEN 'OBSERVADO'
             WHEN AIA.INVOICE_NUM IS NOT NULL AND ABS(EER.EXPENSE_REPORT_TOTAL - AIA.INVOICE_AMOUNT) > 0.01
                  THEN 'OBSERVADO'
             WHEN AIA.INVOICE_NUM IS NOT NULL AND AIA.GL_DATE IS NOT NULL
                  THEN 'CONCILIADO'
             WHEN EER.EXPENSE_STATUS_CODE IN ('READY_FOR_PAYMENT', 'APPROVED', 'PENDING_PAYMENT') 
               OR (AIA.INVOICE_NUM IS NOT NULL AND AIA.GL_DATE IS NULL)
                  THEN 'PENDIENTE DE MIGRACION'
             ELSE 'PENDIENTE DE MIGRACION'
        END                                             RESULTADO_CONCILIACION
        ,EER.ORG_ID                                     ORG_ID
        ,EER.EXPENSE_REPORT_ID                          EXPENSE_REPORT_ID
        ,EE.EXPENSE_ID                                  EXPENSE_ID
    FROM
         EXM_EXPENSE_REPORTS           EER
        ,EXM_EXPENSES                  EE
        ,AP_INVOICES_ALL               AIA
        ,PROVEEDOR_POR_FACTURA         PPF
        ,CUENTA_CONTABLE_POR_GASTO     CCPG
        ,ADELANTOS_POR_INFORME         API
        ,PER_PERSON_NAMES_F            PPNF
        ,PER_ALL_PEOPLE_F              PAPF
        ,HR_ALL_ORGANIZATION_UNITS_VL  HAOUV
        ,FUN_ALL_BUSINESS_UNITS_V      FABUV
        ,XLE_ENTITY_PROFILES           XEP
        ,GL_LEDGERS                    GL
        ,EXM_EXPENSE_TYPES             ET
        ,POZ_SUPPLIERS_V               PS
        -- NUEVO: distribuciones AP
        ,DISTRIBUCIONES_AP             DAP
    WHERE
        EER.EXPENSE_REPORT_NUM = AIA.INVOICE_NUM(+)
        AND EER.EXPENSE_REPORT_ID = EE.EXPENSE_REPORT_ID
        AND EE.EXPENSE_ID NOT IN (
            SELECT EXPENSE_ID_PADRE 
            FROM LINEAS_PADRE_EXCLUIR
        )
        AND AIA.INVOICE_ID = PPF.INVOICE_ID(+) 
        AND PPF.RN(+) = 1
        AND EE.EXPENSE_ID = CCPG.EXPENSE_ID(+) 
        AND CCPG.RN(+) = 1
        AND EER.EXPENSE_REPORT_ID = API.EXPENSE_REPORT_ID(+)
        AND EER.PERSON_ID = PPNF.PERSON_ID(+)
        AND PPNF.NAME_TYPE(+) = 'GLOBAL'
        AND TRUNC(SYSDATE) BETWEEN PPNF.EFFECTIVE_START_DATE(+) 
        AND PPNF.EFFECTIVE_END_DATE(+)
        AND EER.PERSON_ID = PAPF.PERSON_ID(+)                                                              
        AND TRUNC(SYSDATE) BETWEEN PAPF.EFFECTIVE_START_DATE(+) 
        AND PAPF.EFFECTIVE_END_DATE(+) 
        AND EER.ORG_ID = HAOUV.ORGANIZATION_ID
        AND HAOUV.NAME = FABUV.BU_NAME(+)
        AND TO_NUMBER(FABUV.PRIMARY_LEDGER_ID) = GL.LEDGER_ID(+)
        AND TO_NUMBER(FABUV.LEGAL_ENTITY_ID) = XEP.LEGAL_ENTITY_ID(+)                                                      
        AND TRUNC(SYSDATE) BETWEEN NVL(XEP.EFFECTIVE_FROM(+), TO_DATE('01/01/1900','DD/MM/YYYY')) 
                                AND NVL(XEP.EFFECTIVE_TO(+), TO_DATE('31/12/4712','DD/MM/YYYY'))      
        AND HAOUV.NAME IN ('ARCAF','CLID','PEBPE','PYBPY','UYBUY')
        AND HAOUV.NAME = NVL(:P_UNIDAD_NEGOCIO, HAOUV.NAME)
        AND TRUNC(EER.EXPENSE_REPORT_DATE) >= NVL(:P_FECHA_DESDE, TRUNC(EER.EXPENSE_REPORT_DATE))
        AND TRUNC(EER.EXPENSE_REPORT_DATE) <= NVL(:P_FECHA_HASTA, TRUNC(EER.EXPENSE_REPORT_DATE))
        AND EER.PERSON_ID = NVL(:P_COLABORADOR_ID, EER.PERSON_ID) 
        AND EER.EXPENSE_STATUS_CODE = NVL(:P_ESTADO_EXPENSES, EER.EXPENSE_STATUS_CODE)
        AND EER.REIMBURSEMENT_CURRENCY_CODE = NVL(:P_MONEDA, EER.REIMBURSEMENT_CURRENCY_CODE)
        AND (UPPER(PPF.MERCHANT_NAME) LIKE '%' || UPPER(:P_PROVEEDOR) || '%' OR :P_PROVEEDOR IS NULL)
        AND EE.EXPENSE_TYPE_ID = ET.EXPENSE_TYPE_ID(+)
        AND AIA.VENDOR_ID = PS.VENDOR_ID(+)
        -- NUEVO: join a distribuciones AP (puede haber varias por invoice)
        AND AIA.INVOICE_ID = DAP.INVOICE_ID(+)
)
SELECT * 
FROM BASE_DATOS
WHERE RESULTADO_CONCILIACION = NVL(:P_RESULTADO_CONCILIACION, RESULTADO_CONCILIACION)