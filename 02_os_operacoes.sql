-- =============================================================================
-- 02_os_operacoes.sql                                        [NACIONAL r2]
-- Substitui : sync_patio_total.py -> SAP_OS_DETALHES_QUERY
-- Destino   : public.sap_os_operacoes
--
-- MUDANÇAS r2 (escopo nacional, 19/08/2026):
--   1. Filtro de filial (BHZ/BET) REMOVIDO; CRHD vira LEFT JOIN de dicionário
--      e a filial sai como coluna (prefixo do ARBPL antes do '|').
--      Ordens sem centro de trabalho não somem.
--   2. Mantido o recorte de negócio ILART IN ('PRP','OFI') — é tipo de
--      manutenção, não filial.
--   3. Status da operação: o join da JEST ganhou TRIM (padding da réplica)
--      e SPRAS padronizado em 'P' (o valor comprovado desta réplica).
--   4. OBJTY tolerante mantido nos dois usos da CRHD.
--
-- Performance nacional: `os_campeas` limita o universo a última OS por
-- ativo × tipo ANTES de expandir operações — o fan-out nacional fica
-- proporcional à frota, não ao histórico.
-- =============================================================================

WITH ct AS (
    SELECT
        c.objid,
        c.arbpl,
        COALESCE(NULLIF(split_part(c.arbpl, '|', 1), ''), c.arbpl) AS filial
    FROM crhd c
    WHERE UPPER(TRIM(COALESCE(c.objty, ''))) IN ('A', '')
),

base_os AS (
    SELECT
        a.aufnr,
        a.ktext                                   AS descricao_os,
        a.erdat                                   AS data_criacao,
        a.ernam                                   AS autor_os,
        a.idat1                                   AS data_liberacao,
        NULLIF(LTRIM(TRIM(h.equnr), '0'), '')     AS ativo,
        ct.arbpl                                  AS centro_trabalho_cabecalho,
        ct.filial,
        CASE
            WHEN h.ilart = 'PRP' THEN 'Preparação'
            WHEN h.ilart = 'OFI' THEN 'Oficina'
            ELSE 'Outro'
        END AS tipo_manutencao
    FROM aufk a
    JOIN afih h  ON h.aufnr = a.aufnr
    LEFT JOIN ct ON ct.objid = h.gewrk            -- LEFT: sem centro != sem OS
    WHERE a.erdat >= '2024-01-01'   -- erdat é VARCHAR neste lake (ISO); comparação textual usa o índice
      AND h.ilart IN ('PRP', 'OFI')
      AND h.equnr IS NOT NULL
      AND TRIM(h.equnr) <> ''
),

os_campeas AS (
    SELECT DISTINCT ON (b.ativo, b.tipo_manutencao) b.*
    FROM base_os b
    ORDER BY b.ativo, b.tipo_manutencao, b.data_criacao DESC, b.aufnr DESC
),

planejamento AS (
    -- AFKO é 1:1 com AUFNR: join direto, sem agregação.
    SELECT
        o.aufnr,
        k.gstrp AS data_inicio_programada,
        k.gltrp AS data_fim_programada,
        k.aufpl
    FROM os_campeas o
    JOIN afko k ON k.aufnr = o.aufnr
),

operacoes AS (
    SELECT
        p.aufnr,
        v.vornr        AS num_operacao,
        v.ltxa1        AS descricao_operacao,
        co.arbpl       AS centro_trabalho_operacao,
        vv.arbei       AS tempo_previsto_h,
        v.objnr
    FROM planejamento p
    JOIN afvc v       ON v.aufpl = p.aufpl
    LEFT JOIN afvv vv ON vv.aufpl = v.aufpl AND vv.aplzl = v.aplzl
    LEFT JOIN crhd co ON co.objid = v.arbid
                     AND UPPER(TRIM(COALESCE(co.objty, ''))) IN ('A', '')
),

status_op AS (
    -- TRIM: nesta réplica jest.objnr vem com padding (comprovado 12/08/2026).
    SELECT
        o.objnr,
        string_agg(st.txt04, ' ' ORDER BY st.txt04) AS status_operacao
    FROM (SELECT DISTINCT objnr FROM operacoes WHERE objnr IS NOT NULL) o
    JOIN jest j   ON TRIM(BOTH FROM j.objnr) = TRIM(BOTH FROM o.objnr)
                 AND COALESCE(j.inact, '') <> 'X'
    JOIN tj02t st ON st.istat = j.stat
                 AND st.spras = 'P'
    GROUP BY o.objnr
)

SELECT
    o.ativo,
    o.filial,
    TRIM(LEADING '0' FROM o.aufnr)          AS ordem,
    o.tipo_manutencao,
    o.descricao_os,
    o.centro_trabalho_cabecalho             AS centro_trabalho_responsavel,
    p.data_inicio_programada,
    p.data_fim_programada,
    o.data_liberacao,
    o.autor_os,
    op.num_operacao,
    op.descricao_operacao,
    op.centro_trabalho_operacao,
    op.tempo_previsto_h,
    s.status_operacao
FROM os_campeas o
JOIN planejamento p   ON p.aufnr  = o.aufnr
JOIN operacoes op     ON op.aufnr = o.aufnr
LEFT JOIN status_op s ON s.objnr  = op.objnr
ORDER BY o.filial NULLS LAST, o.ativo, o.aufnr, op.num_operacao;
