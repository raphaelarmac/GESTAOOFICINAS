-- =============================================================================
-- 01_ordens_servico_sap.sql                                  [NACIONAL r2]
-- Substitui : sync_patio_total.py -> SAP_QUERY
-- Destino   : public.sap_os_records
--
-- MUDANÇAS r2 (escopo nacional, 19/08/2026):
--   1. FILIAL VIROU COLUNA, NÃO FILTRO. O CT de BHZ/BET sumiu; a CRHD entra
--      como LEFT JOIN só para dar nome ao centro. Ordens sem centro de
--      trabalho NÃO somem mais (lição do relatório dos planejadores).
--   2. `filial` derivada genericamente: prefixo do ARBPL antes do '|'
--      ('BHZ|MANU' -> 'BHZ', 'POA|OFICINA' -> 'POA'). Centro sem '|' usa o
--      próprio ARBPL; ordem sem centro sai filial NULL (o app decide o rótulo).
--   3. Joins de status com TRIM em jest/jsto.objnr e tj30t.stsma — nesta
--      réplica essas colunas vêm com padding (view v1 da engenharia prova).
--      Índices de expressão correspondentes estão no 99.
--   4. OBJTY tolerante mantido (diagnóstico 12/08: = 'A' casa 0 linhas).
--
-- Performance nacional: a base é AUFK+AFIH desde 2024 no Brasil todo
-- (~466 mil ordens medidas em 12/08/2026), mas o resultado continua limitado
-- a "última OS por ativo × tipo" e o status só é buscado para as campeãs.
-- Com ix_aufk_erdat + ix_afih_aufnr + índices de expressão do 99, escala bem.
-- =============================================================================

WITH ct AS (
    -- Centros de trabalho: agora é só dicionário OBJID -> nome/filial
    SELECT
        c.objid,
        c.arbpl,
        COALESCE(NULLIF(split_part(c.arbpl, '|', 1), ''), c.arbpl) AS filial
    FROM crhd c
    WHERE UPPER(TRIM(COALESCE(c.objty, ''))) IN ('A', '')
),

txt_atividade AS (
    SELECT DISTINCT ON (t.ilart) t.ilart, t.ilatx
    FROM t353i_t t
    WHERE t.spras = 'P'
    ORDER BY t.ilart, t.iwerk
),

txt_prioridade AS (
    SELECT DISTINCT ON (p.priok) p.priok, p.priokx
    FROM t356_t p
    WHERE p.spras = 'P'
    ORDER BY p.priok, p.artpr
),

ordens AS (
    SELECT
        a.aufnr,
        a.objnr,
        a.erdat                                         AS data_criacao,
        a.idat1, a.idat2, a.idat3,
        a.loekz,
        a.priok,
        NULLIF(LTRIM(TRIM(h.equnr), '0'), '')           AS ativo,
        h.ilart,
        ct.arbpl                                        AS centro_trabalho,
        ct.filial
    FROM aufk a
    JOIN afih h    ON h.aufnr = a.aufnr
    LEFT JOIN ct   ON ct.objid = h.gewrk               -- LEFT: sem centro != sem OS
    WHERE a.erdat >= '2024-01-01'   -- erdat é VARCHAR neste lake (ISO); comparação textual usa o índice
      AND h.equnr IS NOT NULL
      AND TRIM(h.equnr) <> ''
      -- Descomente se ordens marcadas para eliminação não devem aparecer:
      -- AND COALESCE(a.loekz, '') <> 'X'
),

classificada AS (
    SELECT
        o.*,
        ta.ilatx AS tipo_atividade,
        CASE
            WHEN o.ilart = 'PRP'
              OR strpos(lower(COALESCE(ta.ilatx, '')), 'prep') > 0 THEN 'Preparação'
            WHEN o.ilart = 'OFI'
              OR strpos(lower(COALESCE(ta.ilatx, '')), 'ofi')  > 0 THEN 'Oficina'
            ELSE 'Outro'
        END AS tipo_manutencao
    FROM ordens o
    LEFT JOIN txt_atividade ta ON ta.ilart = o.ilart
),

ultima_os_por_tipo AS (
    SELECT DISTINCT ON (c.ativo, c.tipo_manutencao)
        c.ativo,
        c.filial,
        c.centro_trabalho,
        c.aufnr,
        c.objnr,
        c.tipo_manutencao,
        c.tipo_atividade,
        c.priok,
        c.data_criacao,
        CASE
            WHEN c.idat3 IS NOT NULL THEN '3 - Encerrada Comercial'
            WHEN c.idat2 IS NOT NULL THEN '2 - Concluída Tecnicamente'
            WHEN c.idat1 IS NOT NULL THEN '1 - Liberada'
            ELSE '0 - Criada / Aberta'
        END AS fase_os
    FROM classificada c
    WHERE c.tipo_manutencao IN ('Oficina', 'Preparação')
    ORDER BY c.ativo, c.tipo_manutencao, c.data_criacao DESC, c.aufnr DESC
),

status_usuario AS (
    -- Só para as campeãs. TRIM nos dois lados: nesta réplica jest/jsto.objnr
    -- e tj30t.stsma vêm com padding (comprovado na view v1 da engenharia).
    SELECT
        u.aufnr,
        string_agg(t.txt04, ' ' ORDER BY t.txt04) AS status_usuario
    FROM ultima_os_por_tipo u
    JOIN jsto s  ON TRIM(BOTH FROM s.objnr) = TRIM(BOTH FROM u.objnr)
    JOIN jest j  ON TRIM(BOTH FROM j.objnr) = TRIM(BOTH FROM u.objnr)
                AND COALESCE(j.inact, '') <> 'X'
                AND left(j.stat, 1) = 'E'
    JOIN tj30t t ON TRIM(BOTH FROM t.stsma) = TRIM(BOTH FROM s.stsma)
                AND t.estat = j.stat
                AND t.spras = 'P'
    GROUP BY u.aufnr
)

SELECT
    u.ativo,
    u.filial,
    u.centro_trabalho,
    TRIM(LEADING '0' FROM u.aufnr)          AS ordem,
    u.tipo_manutencao,
    u.tipo_atividade,
    COALESCE(tp.priokx, u.priok)            AS criticidade,
    u.fase_os,
    su.status_usuario,
    u.data_criacao
FROM ultima_os_por_tipo u
LEFT JOIN txt_prioridade tp ON tp.priok = u.priok
LEFT JOIN status_usuario su ON su.aufnr = u.aufnr
ORDER BY u.filial NULLS LAST, u.ativo, u.tipo_manutencao;
