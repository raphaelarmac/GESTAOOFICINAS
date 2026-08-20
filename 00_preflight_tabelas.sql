-- =============================================================================
-- 00_preflight_tabelas.sql
-- RODE ISTO PRIMEIRO.
--
-- As queries reescritas leem direto das tabelas nativas do SAP. Este script
-- verifica quais dessas tabelas realmente existem na sua réplica antes de
-- você trocar qualquer coisa em produção.
--
-- Dialeto: PostgreSQL (mesmo dialeto das queries originais - ILIKE, ::text,
--          LATERAL, DISTINCT ON, "/scwm/aqua").
-- =============================================================================

WITH esperadas(tabela, usada_em, criticidade) AS (
    VALUES
        -- Ordens de manutenção (substituem pm_ordem_manutencao_cabecalho_v2)
        ('aufk',   '01, 02, 04, 10, 15', 'BLOQUEANTE'),
        ('afih',   '01, 02, 04, 10, 15', 'BLOQUEANTE'),
        ('afko',   '02, 10',             'BLOQUEANTE'),
        ('afvc',   '02',                 'BLOQUEANTE'),
        ('afvv',   '02',                 'importante'),
        ('crhd',   '01, 02, 10',         'BLOQUEANTE'),
        ('jest',   '01, 02, 03, 10',     'BLOQUEANTE'),
        ('jsto',   '01, 10',             'BLOQUEANTE'),
        ('tj02t',  '02',                 'importante'),
        ('tj30t',  '01, 10',             'importante'),
        ('t003p',  '10',                 'importante'),
        ('t353i_t','01, 04, 10',         'importante'),
        ('t356_t', '01, 10',             'opcional'),
        ('t024i',  '10',                 'opcional'),
        -- Equipamentos (substituem armac.fi_ativos)
        ('equi',   '03',                 'BLOQUEANTE'),
        ('eqkt',   '03, 15',             'BLOQUEANTE'),
        ('equz',   '03',                 'importante'),
        ('iloa',   '03',                 'importante'),
        -- Compras / suprimentos
        ('eban',   '04, 05',             'BLOQUEANTE'),
        ('ebkn',   '04, 05',             'BLOQUEANTE'),
        ('ekpo',   '04, 05, 13',         'BLOQUEANTE'),
        ('ekko',   '05, 13',             'BLOQUEANTE'),
        ('ekkn',   '05',                 'importante'),
        ('ekbe',   '05, 13',             'BLOQUEANTE'),
        ('eket',   '05',                 'importante'),
        ('lfa1',   '05',                 'importante'),
        -- Materiais / reservas
        ('resb',   '04, 10, 15',         'BLOQUEANTE'),
        ('rkpf',   '10',                 'BLOQUEANTE'),
        ('rsadd',  '10',                 'opcional'),
        ('makt',   '04, 05, 10, 15',     'BLOQUEANTE'),
        ('mara',   '10, 15',             'BLOQUEANTE'),
        ('lips',   '10',                 'opcional'),
        ('csks',   '10',                 'importante'),
        ('cepct',  '10',                 'opcional'),
        ('anlh',   '10',                 'opcional'),
        ('usr21',  '10',                 'opcional'),
        ('adr6',   '01 (email TODO)',      'opcional'),
        ('adrp',   '10',                 'opcional'),
        ('ztwf_log_wf', '10',            'importante'),
        ('/scwm/aqua',  '10',            'importante'),
        -- Fontes não-SAP (apps internos) - devem continuar existindo
        ('relatorio_entrada_saida_uca', '06, 07', 'BLOQUEANTE'),
        ('hourmeter',                   '08',     'BLOQUEANTE'),
        ('hourmeter_invalid',           '09',     'BLOQUEANTE'),
        ('evidencia_recebimentos',      '14',     'BLOQUEANTE'),
        ('requisicoes_de_compra',       '14',     'BLOQUEANTE')
)
SELECT
    e.tabela,
    e.usada_em                                        AS usada_nas_queries,
    e.criticidade,
    COALESCE(c.table_schema, '--- NAO ENCONTRADA ---') AS schema_encontrado,
    CASE WHEN c.table_schema IS NULL THEN 'FALTA' ELSE 'ok' END AS situacao
FROM esperadas e
LEFT JOIN LATERAL (
    SELECT t.table_schema
    FROM information_schema.tables t
    WHERE lower(t.table_name) = lower(e.tabela)
    ORDER BY (t.table_schema = 'public') DESC, t.table_schema
    LIMIT 1
) c ON TRUE
ORDER BY
    CASE WHEN c.table_schema IS NULL THEN 0 ELSE 1 END,
    CASE e.criticidade WHEN 'BLOQUEANTE' THEN 0 WHEN 'importante' THEN 1 ELSE 2 END,
    e.tabela;


-- -----------------------------------------------------------------------------
-- Colunas realmente disponíveis nas tabelas-chave (confira antes de rodar 01/03)
-- -----------------------------------------------------------------------------
SELECT table_schema, table_name, column_name, data_type
FROM information_schema.columns
WHERE lower(table_name) IN ('aufk','afih','crhd','equi','equz','iloa','jest','jsto')
ORDER BY table_name, ordinal_position;


-- -----------------------------------------------------------------------------
-- Tipo de dado das colunas de data usadas em filtro.
-- ATENÇÃO: nas queries originais AUFK.ERDAT é comparado com DATE ('2024-01-01')
-- e EBAN.BADAT é comparado com TEXTO ('YYYYMMDD'). Confirme aqui qual é qual —
-- comparar texto com data força cast e derruba o índice.
-- -----------------------------------------------------------------------------
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE (lower(table_name), lower(column_name)) IN (
        ('aufk','erdat'), ('aufk','idat1'), ('aufk','idat2'), ('aufk','idat3'),
        ('eban','badat'), ('ekko','bedat'), ('eket','eindt'), ('ekbe','budat'),
        ('afko','gstrp'), ('afko','gltrp'), ('equi','baujj')
      )
ORDER BY table_name, column_name;


-- -----------------------------------------------------------------------------
-- [PATCH ARMAC r1] Valores reais de OBJTY e SPRAS nesta réplica.
-- Diagnóstico de 12/08/2026: OBJTY = 'A' retornou 0 linhas; OBJID não duplica.
-- As queries 01/02/04/10 usam predicado tolerante por causa disto.
-- -----------------------------------------------------------------------------
SELECT DISTINCT objty, LENGTH(objty) AS tam, COUNT(*) AS qtd
FROM crhd GROUP BY 1, 2 ORDER BY 3 DESC;

SELECT objid, COUNT(*) FROM crhd GROUP BY objid HAVING COUNT(*) > 1 LIMIT 5;

SELECT 'tj02t' AS tabela, spras, COUNT(*) FROM tj02t GROUP BY 2
UNION ALL
SELECT 'tj30t', spras, COUNT(*) FROM tj30t GROUP BY 2
ORDER BY 1, 3 DESC;
