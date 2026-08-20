-- =============================================================================
-- [PATCH ARMAC r1] OBJTY tolerante: diagnóstico de 12/08/2026 provou que
-- nesta réplica CRHD.OBJTY não casa com = 'A' (0 linhas) e OBJID não duplica.
-- 04_os_suprimentos.sql                                       [NACIONAL r2]
-- MUDANÇAS r2 (19/08/2026): filtro BHZ/BET removido; CRHD virou LEFT JOIN de
-- dicionário e a FILIAL sai como coluna em todas as etapas. Ordens sem centro
-- não somem. OBJTY tolerante mantido.
-- Substitui : sync_patio_total.py -> SUPRIMENTOS_QUERY
-- Destino   : public.os_suprimentos
-- Mudança   : lê direto de AUFK/AFIH/CRHD (sem pm_ordem_manutencao_cabecalho_v2)
--
-- Ganhos de performance:
--   1. Some o LPAD(TRIM(n_ordem), 12, '0'): AUFK.AUFNR já é CHAR(12) com zeros
--      à esquerda no SAP. Os joins com EBKN.AUFNR e RESB.AUFNR passam a ser
--      igualdade coluna-a-coluna, o que permite usar índice. Antes o LPAD era
--      recalculado e comparado a cada linha.
--   2. CRHD filtrada antes (INNER JOIN por OBJID) em vez de LIKE '%BHZ%' sobre
--      a base de ordens.
--   3. ROW_NUMBER()+rn=1 -> DISTINCT ON, nas duas etapas.
--   4. MAKT resolvida via DISTINCT ON restrito aos materiais em jogo.
--   5. Sem `%` na query.
--
-- Correções de bug:
--   * O PARTITION BY original tinha um CASE sem ELSE: ordens que não caíam em
--     PRP/OFI iam todas para a partição NULL e competiam entre si. Agora a
--     classificação é explícita e filtrada antes do desempate.
--   * Desempate por data_criacao ganhou tiebreaker aufnr DESC (era
--     não-determinístico).
--   * O filtro `R.XLOEK IS NULL OR TRIM(R.XLOEK) = ''` foi mantido, mas escrito
--     como IS DISTINCT FROM 'X' (mesma intenção, sem depender de NULL vs '').
-- =============================================================================

WITH ct AS (
    -- [NACIONAL r2] dicionário de centros (sem filtro de filial)
    SELECT
        c.objid,
        COALESCE(NULLIF(split_part(c.arbpl, '|', 1), ''), c.arbpl) AS filial
    FROM crhd c
    WHERE UPPER(TRIM(COALESCE(c.objty, ''))) IN ('A', '')
),

ordens AS (
    SELECT
        a.aufnr,                                        -- CHAR(12), com zeros
        NULLIF(LTRIM(TRIM(h.equnr), '0'), '') AS ativo,
        a.erdat,
        CASE WHEN h.ilart = 'PRP' THEN 'Preparação'
             WHEN h.ilart = 'OFI' THEN 'Oficina'
        END AS tipo_manutencao,
        ct.filial                                      -- [NACIONAL r2]
    FROM aufk a
    JOIN afih h  ON h.aufnr = a.aufnr
    LEFT JOIN ct ON ct.objid = h.gewrk                 -- [NACIONAL r2] LEFT
    WHERE a.erdat >= DATE '2024-01-01'
      AND h.ilart IN ('PRP', 'OFI')
      AND h.equnr IS NOT NULL
      AND TRIM(h.equnr) <> ''
),

ultima_os AS (
    SELECT DISTINCT ON (o.ativo, o.tipo_manutencao)
        o.ativo,
        o.filial,                                -- [NACIONAL r2]
        o.aufnr                                  AS ordem_sap,
        TRIM(LEADING '0' FROM o.aufnr)           AS ordem
    FROM ordens o
    ORDER BY o.ativo, o.tipo_manutencao, o.erdat DESC, o.aufnr DESC
),

itens_brutos AS (
    -- (a) itens vindos de requisição de compra imputada na ordem
    SELECT
        os.ativo,
        os.filial,
        os.ordem,
        LTRIM(TRIM(e.matnr), '0')      AS cod_sap,
        e.txz01                        AS desc_compra_direta,
        e.menge                        AS qtd_req,
        LTRIM(TRIM(p.ebeln), '0')      AS pedido,
        NULL::varchar                  AS num_reserva,
        'compra'::text                 AS origem,
        e.knttp
    FROM ultima_os os
    JOIN ebkn acc    ON acc.aufnr = os.ordem_sap
    JOIN eban e      ON e.banfn = acc.banfn AND e.bnfpo = acc.bnfpo
    LEFT JOIN ekpo p ON p.banfn = e.banfn   AND p.bnfpo = e.bnfpo

    UNION ALL

    -- (b) itens vindos da reserva da ordem
    SELECT
        os.ativo,
        os.filial,
        os.ordem,
        LTRIM(TRIM(r.matnr), '0')      AS cod_sap,
        NULL::varchar                  AS desc_compra_direta,
        r.bdmng                        AS qtd_req,
        LTRIM(TRIM(p.ebeln), '0')      AS pedido,
        CASE WHEN r.postp = 'N' THEN NULL::varchar
             ELSE LTRIM(TRIM(r.rsnum), '0') END AS num_reserva,
        CASE WHEN r.postp = 'N' THEN 'compra'::text
             ELSE 'reserva'::text END           AS origem,
        e.knttp
    FROM ultima_os os
    JOIN resb r      ON r.aufnr = os.ordem_sap
    LEFT JOIN eban e ON e.banfn = r.banfn AND e.bnfpo = r.bnfpo
    LEFT JOIN ekpo p ON p.banfn = e.banfn AND p.bnfpo = e.bnfpo
    WHERE r.xloek IS DISTINCT FROM 'X'
),

itens_validos AS (
    SELECT * FROM itens_brutos
    WHERE cod_sap IS NOT NULL AND cod_sap <> ''
),

descricoes AS (
    SELECT DISTINCT ON (mat) mat, maktx
    FROM (
        SELECT LTRIM(TRIM(m.matnr), '0') AS mat, m.maktx, m.spras
        FROM makt m
        WHERE lower(m.spras) IN ('p', 'pt')
          AND LTRIM(TRIM(m.matnr), '0') IN (SELECT DISTINCT cod_sap FROM itens_validos)
    ) s
    ORDER BY mat, spras
),

itens_deduplicados AS (
    SELECT DISTINCT ON (i.ordem, i.cod_sap) i.*
    FROM itens_validos i
    ORDER BY
        i.ordem,
        i.cod_sap,
        CASE WHEN i.origem = 'compra'       THEN 1 ELSE 2 END,
        CASE WHEN i.pedido IS NOT NULL      THEN 1 ELSE 2 END,
        CASE WHEN i.num_reserva IS NOT NULL THEN 1 ELSE 2 END
)

SELECT
    i.ativo,
    i.filial,
    i.ordem,
    i.cod_sap,
    COALESCE(d.maktx, i.desc_compra_direta, 'Sem Descrição') AS descricao,
    i.qtd_req,
    i.num_reserva,
    i.pedido,
    i.origem,
    NULLIF(TRIM(COALESCE(i.knttp, '')), '')                  AS knttp,
    CASE
        WHEN COALESCE(TRIM(i.knttp), '') = '' THEN 'estoque'
        WHEN TRIM(i.knttp) = 'K'              THEN 'centro_custo'
        ELSE 'consumo'
    END AS destinacao
FROM itens_deduplicados i
LEFT JOIN descricoes d ON d.mat = i.cod_sap
ORDER BY i.ativo, i.ordem;
