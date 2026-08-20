-- =============================================================================
-- 00b_extrair_ddl_views_atuais.sql
--
-- As reescritas em 01 e 03 são baseadas no mapeamento padrão do SAP PM/EAM.
-- Para ficarem 100% fiéis ao que o app entrega hoje, extraia a definição das
-- views que estamos removendo e compare campo a campo com o README.
--
-- Rode a parte (A) no Postgres e a parte (B) no HANA.
-- =============================================================================

-- (A) PostgreSQL --------------------------------------------------------------
SELECT n.nspname AS schema,
       c.relname AS objeto,
       CASE c.relkind WHEN 'v' THEN 'view'
                      WHEN 'm' THEN 'materialized view'
                      WHEN 'r' THEN 'tabela' END AS tipo,
       pg_get_viewdef(c.oid, true) AS definicao
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname IN (
        'pm_ordem_manutencao_cabecalho_v2',
        'bi_bs_fluxo_aprov'
      )
ORDER BY 1, 2;


-- (B) SAP HANA ----------------------------------------------------------------
-- SELECT SCHEMA_NAME, VIEW_NAME, DEFINITION
-- FROM SYS.VIEWS
-- WHERE VIEW_NAME = 'FI_ATIVOS' OR SCHEMA_NAME = 'ARMAC';
--
-- SELECT SCHEMA_NAME, VIEW_NAME, COLUMN_NAME, DATA_TYPE_NAME, LENGTH
-- FROM SYS.VIEW_COLUMNS
-- WHERE VIEW_NAME = 'FI_ATIVOS'
-- ORDER BY POSITION;
