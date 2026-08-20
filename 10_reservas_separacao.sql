-- =============================================================================
-- [PATCH ARMAC r1] OBJTY tolerante: diagnóstico de 12/08/2026 provou que
-- nesta réplica CRHD.OBJTY não casa com = 'A' (0 linhas) e OBJID não duplica.
-- 10_reservas_separacao.sql
-- Substitui : sync_reservas_separacao.py -> RESERVAS_SEPARACAO_QUERY
-- Destino   : public.reservas_separacao / public.reservas_separacao_itens
-- Mudança   : lê direto de AUFK/AFIH/AFKO/CRHD/JEST (sem
--             pm_ordem_manutencao_cabecalho_v2)
--
-- Esta era a query mais cara das 15. As mudanças, em ordem de impacto:
--
--   1. SELECT DISTINCT REMOVIDO. Ele estava lá para mascarar 5 joins que
--      duplicam linha (LIPS, CSKS, CEPCT, ANLH, ADRP - todos têm chave
--      composta que a query ignorava). Deduplicar ~65 colunas, incluindo um
--      string_agg, obriga o Postgres a ordenar o resultado inteiro em disco.
--      Agora cada um desses joins é resolvido com DISTINCT ON na origem e o
--      resultado final já sai único, sem sort global.
--
--   2. EWM: antes a CTE `ewm_base` varria TODA a /scwm/aqua (com LEFT JOIN em
--      MARA) e só filtrava os materiais depois, na CTE seguinte. Agora a
--      varredura começa por MARA restrita aos materiais das reservas.
--
--   3. As ordens de manutenção deixam de vir da view e são lidas direto do SAP,
--      já restritas às ordens que aparecem nas reservas.
--
-- >>> DOIS BUGS CORRIGIDOS - CONFIRA O IMPACTO NA CONTAGEM DE LINHAS <<<
--   (a) `sgtxt <> 'Item não estocável'` descartava silenciosamente todas as
--       linhas com SGTXT NULL (em SQL, NULL <> 'x' é NULL, não TRUE).
--   (b) `xloek <> 'X'` tinha o mesmo problema: reservas não canceladas com
--       XLOEK NULL sumiam.
--   Ambos viraram IS DISTINCT FROM. Rode o comparativo de contagem que está no
--   rodapé deste arquivo antes de subir. Se a intenção original era mesmo
--   excluir os NULLs, troque de volta.
--
-- Campos sem equivalente direto no SAP estão marcados com TODO e saem NULL:
-- eram enriquecimentos feitos na própria view (ver README).
-- =============================================================================

WITH base_resb AS (
    SELECT
        r.rsnum, r.rspos, r.matnr, r.bdmng, r.enmng, r.werks, r.lgort,
        r.bwart, r.sgtxt, r.wempf, r.ablad, r.objnr, r.xloek, r.kzear,
        r.postp, r.xwaok,
        (LPAD(TRIM(r.rsnum)::text, 10, '0') || LPAD(TRIM(r.rspos)::text, 4, '0')) AS chave_reserva
    FROM resb r
    WHERE r.lgort IN ('D005', 'D090')
      AND r.bwart IN ('201', '261')
      AND r.sgtxt IS DISTINCT FROM 'Item não estocável'   -- (a) ver cabeçalho
      AND r.xloek IS DISTINCT FROM 'X'                    -- (b) ver cabeçalho
      AND (r.postp = 'L' OR r.postp IS NULL OR r.postp = '')
),

materiais_base AS (
    SELECT DISTINCT TRIM(LEADING '0' FROM TRIM(matnr)) AS material_limpo
    FROM base_resb
),

ordens_base AS (
    SELECT DISTINCT k.aufnr
    FROM base_resb b
    JOIN rkpf k ON k.rsnum = b.rsnum
    WHERE k.aufnr IS NOT NULL AND TRIM(k.aufnr) <> ''
),

-- ---------------------------------------------------------------- textos SAP
tipos_ordem AS (
    SELECT DISTINCT ON (t.auart) t.auart, t.txt
    FROM t003p t
    WHERE t.spras = 'P'
    ORDER BY t.auart
),

txt_atividade AS (
    SELECT DISTINCT ON (t.ilart) t.ilart, t.ilatx
    FROM t353i_t t
    WHERE t.spras = 'P'
    ORDER BY t.ilart, t.ilatx   -- desempate por texto (t353i_t não tem iwerk)
),

txt_prioridade AS (
    SELECT DISTINCT ON (p.priok) p.priok, p.priokx
    FROM t356_t p
    WHERE p.spras = 'P'
    ORDER BY p.priok, p.artpr
),

txt_grupo_plan AS (
    SELECT DISTINCT ON (g.ingrp) g.ingrp, g.innam
    FROM t024i g
    ORDER BY g.ingrp, g.iwerk
),

-- --------------------------------------------------- ordens direto do SAP PM
ordens AS (
    SELECT
        a.aufnr,
        a.objnr,
        a.auart,
        a.ktext,
        a.priok,
        a.kostl,
        a.erdat,
        a.ernam,
        a.aedat,
        a.aenam,
        a.idat1, a.idat2, a.idat3,
        a.loekz,
        NULLIF(LTRIM(TRIM(h.equnr), '0'), '') AS n_equipamento,
        h.ilart,
        h.ingpr,
        h.qmnum,
        h.warpl,
        h.wapos,
        h.tplnr,
        c.arbpl                                AS cod_centro_trabalho,
        f.gstrp                                AS dt_inicio_base,
        f.gltrp                                AS dt_fim_base
    FROM ordens_base ob
    JOIN aufk a       ON a.aufnr = ob.aufnr
    LEFT JOIN afih h  ON h.aufnr = a.aufnr
    LEFT JOIN afko f  ON f.aufnr = a.aufnr
    LEFT JOIN crhd c  ON c.objid = h.gewrk AND UPPER(TRIM(COALESCE(c.objty, ''))) IN ('A', '')
),

status_os AS (
    -- Status de usuário da ordem (substitui pm.cod_status_usuario / pm.status_usuario)
    SELECT
        o.aufnr,
        string_agg(j.stat,   ' ' ORDER BY j.stat)   AS cod_status_usuario,
        string_agg(t.txt04,  ' ' ORDER BY t.txt04)  AS status_usuario
    FROM ordens o
    JOIN jsto s  ON TRIM(BOTH FROM s.objnr) = TRIM(BOTH FROM o.objnr)  -- [NACIONAL r2] padding
    JOIN jest j  ON TRIM(BOTH FROM j.objnr) = TRIM(BOTH FROM o.objnr)  -- [NACIONAL r2] padding
                AND COALESCE(j.inact, '') <> 'X'
                AND left(j.stat, 1) = 'E'
    JOIN tj30t t ON TRIM(BOTH FROM t.stsma) = TRIM(BOTH FROM s.stsma)  -- [NACIONAL r2] padding AND t.estat = j.stat AND t.spras = 'P'
    GROUP BY o.aufnr
),

-- ------------------------------------------------------------ EWM / estoque
ewm_base AS (
    -- Começa por MARA já restrita aos materiais das reservas.
    SELECT
        mb.material_limpo                    AS material,
        COALESCE(TRIM(aqua.charg), '')       AS lote,
        COALESCE(aqua.lgpla, '')             AS posicao,
        COALESCE(aqua.quan, 0)               AS quantidade
    FROM materiais_base mb
    JOIN mara m           ON TRIM(LEADING '0' FROM TRIM(m.matnr)) = mb.material_limpo
    JOIN "/scwm/aqua" aqua ON aqua.matid = m.scm_matid_guid16
    WHERE aqua.lgnum = 'OURO'
      AND aqua.quan > 0
),

lotes_ewm_agrupados AS (
    SELECT
        material,
        SUM(qtd_lote) AS saldo_estoque,
        string_agg(
            CASE WHEN NULLIF(lote, '') IS NULL THEN posicoes
                 ELSE lote || ' - ' || posicoes END,
            ' / ' ORDER BY lote
        ) AS lotes_com_posicoes
    FROM (
        SELECT
            material,
            lote,
            SUM(quantidade)                  AS qtd_lote,
            string_agg(DISTINCT posicao, ' | ') AS posicoes
        FROM ewm_base
        GROUP BY material, lote
    ) sub
    GROUP BY material
),

-- --------------------------------------------------------- apoio / cadastros
aprovacao_reservas AS (
    SELECT DISTINCT ON (TRIM(z.chave::text))
        TRIM(z.chave::text)              AS chave,
        NULLIF(TRIM(z.acao::text), '')   AS status,
        NULLIF(TRIM(z.data::text), '')   AS data,
        NULLIF(TRIM(z.hora::text), '')   AS hora
    FROM ztwf_log_wf z
    JOIN base_resb b ON TRIM(z.chave::text) = b.chave_reserva
    ORDER BY TRIM(z.chave::text), z.data DESC NULLS LAST, z.hora DESC NULLS LAST
),

usuarios_sap AS (
    -- ADRP tem chave composta (PERSNUMBER + DATE_FROM + NATION): sem o
    -- DISTINCT ON este join duplicava a linha inteira.
    SELECT DISTINCT ON (TRIM(u.bname))
        TRIM(u.bname)  AS bname_chave,
        p.name_text    AS nome_usuario
    FROM usr21 u
    LEFT JOIN adrp p ON TRIM(p.persnumber) = TRIM(u.persnumber)
    ORDER BY TRIM(u.bname), p.name_text NULLS LAST
),

centro_custo AS (
    SELECT DISTINCT ON (TRIM(c.kostl)) TRIM(c.kostl) AS kostl, c.prctr
    FROM csks c
    ORDER BY TRIM(c.kostl), c.datbi DESC
),

centro_lucro AS (
    SELECT DISTINCT ON (TRIM(p.prctr)) TRIM(p.prctr) AS prctr, p.ltext
    FROM cepct p
    WHERE p.spras = 'P'
    ORDER BY TRIM(p.prctr), p.datbi DESC
),

imobilizado AS (
    SELECT DISTINCT ON (TRIM(a.anln1)) TRIM(a.anln1) AS anln1, a.anlhtxt
    FROM anlh a
    ORDER BY TRIM(a.anln1)
),

remessa AS (
    -- LIPS pode ter mais de uma linha por (rsnum, rspos): fixa uma.
    SELECT DISTINCT ON (l.rsnum, l.rspos) l.rsnum, l.rspos, l.vbeln
    FROM lips l
    JOIN base_resb b ON b.rsnum = l.rsnum AND b.rspos = l.rspos
    ORDER BY l.rsnum, l.rspos, l.vbeln DESC
),

descricao_material AS (
    SELECT DISTINCT ON (mat) mat, maktx
    FROM (
        SELECT TRIM(LEADING '0' FROM TRIM(k.matnr)) AS mat, k.maktx, k.spras
        FROM makt k
        WHERE k.spras = 'P'
          AND TRIM(LEADING '0' FROM TRIM(k.matnr)) IN (SELECT material_limpo FROM materiais_base)
    ) s
    ORDER BY mat, spras
)

SELECT
    COALESCE(resb.rsnum::int, 0)::text        AS numero_reserva,
    LTRIM(TRIM(resb.matnr), '0')              AS codigo,
    dm.maktx                                  AS descr_material,
    resb.bdmng                                AS qtd_reserva,
    COALESCE(resb.enmng, 0)                   AS qtd_retirada,
    resb.kzear                                AS item_baixado,
    COALESCE(resb.rspos::int, 0)::text        AS numero_item,
    resb.chave_reserva                        AS chave,
    COALESCE(o.aufnr::int, 0)::text           AS numero_ordem,
    COALESCE(rsadd.creadat, rkpf.rsdat)       AS data,
    resb.werks                                AS centro,
    resb.lgort                                AS deposito,

    CASE resb.bwart WHEN '201' THEN 'Reserva Manual'
                    WHEN '261' THEN 'Ordem'
                    ELSE '' END               AS descricao_movimentacao,

    COALESCE(tor.txt, '')                     AS tipo_ordem,
    COALESCE(cc.kostl, '')                    AS centro_custo,

    CASE
        WHEN length(TRIM(COALESCE(o.kostl, ''))) = 10 THEN cl.ltext
        WHEN length(TRIM(COALESCE(o.kostl, ''))) = 7  THEN im.anlhtxt
    END                                       AS descricao_ativo,

    rkpf.usnam                                AS criador_reserva,
    uc.nome_usuario                           AS nome_criador_reserva,
    rkpf.lastchangedbyuser                    AS ult_mod_reserva,
    um.nome_usuario                           AS nome_ult_mod_reserva,

    CASE
        WHEN rkpf.lastchangedatetime::text = '0.0000000' THEN ''
        ELSE substring(rkpf.lastchangedatetime::text, 7, 2) || '-' ||
             substring(rkpf.lastchangedatetime::text, 5, 2) || '-' ||
             substring(rkpf.lastchangedatetime::text, 1, 4)
    END                                       AS data_ult_mod_reserva,

    o.ernam                                   AS criador_ordem,
    o.aenam                                   AS ult_mod_ordem,
    ar.status                                 AS aprovacao_reserva,
    ar.data                                   AS data_aprovacao,
    ar.hora                                   AS hora_aprovacao,
    resb.sgtxt                                AS texto,
    resb.wempf                                AS recebedor,
    resb.ablad                                AS ponto_descarga,
    resb.xwaok                                AS status_aprovacao_sap,
    rem.vbeln                                 AS remessa,
    resb.objnr                                AS chavejest,
    resb.xloek                                AS cancelado,
    resb.kzear                                AS finalizado,

    ewm.lotes_com_posicoes,
    COALESCE(ewm.saldo_estoque, 0)            AS saldo_estoque,

    -- ------------------------------------------------ bloco da ordem (ex-view)
    o.n_equipamento,
    o.auart                                   AS cod_tipo_ordem,
    tor.txt                                   AS pm_tipo_ordem,
    o.ktext                                   AS pm_texto_breve,
    o.priok                                   AS cod_prioridade,
    o.cod_centro_trabalho,
    tp.priokx                                 AS prioridade,
    so.cod_status_usuario,
    so.status_usuario,
    o.tplnr                                   AS local_instalacao,
    o.ingpr                                   AS cod_grupo_plan,
    gp.innam                                  AS grupo_plan,
    o.ilart                                   AS cod_tipo_atividade,
    ta.ilatx                                  AS tipo_atividade,
    o.qmnum                                   AS n_nota,
    NULL::varchar                             AS cod_responsavel,        -- TODO(1)
    NULL::varchar                             AS responsavel,            -- TODO(1)
    o.aenam                                   AS cod_ultimo_modificador,
    NULL::varchar                             AS email_ultimo_modificador, -- TODO(2)
    o.aedat                                   AS data_ultima_modificacao,
    NULL::varchar                             AS hora_ultima_modificacao,  -- TODO(3)
    o.aedat::timestamp                        AS datetime_ultima_modificacao, -- TODO(3)
    o.warpl                                   AS n_plano_manutencao,
    NULL::varchar                             AS n_solicitacao_manutencao, -- TODO(4)
    o.wapos                                   AS n_item_manutencao,
    NULL::varchar                             AS n_ultima_ordem,          -- TODO(4)
    CASE WHEN o.idat2 IS NULL AND o.idat3 IS NULL THEN 'X' END AS aberta,
    o.erdat                                   AS data_criacao,
    CASE WHEN o.idat1 IS NOT NULL THEN 'X' END AS liberada,
    o.idat1                                   AS data_liberada,
    CASE WHEN o.idat2 IS NOT NULL THEN 'X' END AS encerrada_tecnicamente,
    o.idat2                                   AS data_encerrada_tecnicamente,
    CASE WHEN o.idat3 IS NOT NULL THEN 'X' END AS encerrada_comercialmente,
    o.idat3                                   AS data_encerrada_comercialmente,
    o.loekz                                   AS marcado_eliminacao,
    NULL::varchar                             AS check_pipefy,            -- TODO(5)
    o.dt_inicio_base,
    o.dt_fim_base,
    NULL::date                                AS dt_venc_final            -- TODO(6)

FROM base_resb resb
LEFT JOIN rkpf                     ON rkpf.rsnum = resb.rsnum
LEFT JOIN ordens o                 ON o.aufnr = rkpf.aufnr
LEFT JOIN tipos_ordem tor          ON tor.auart = o.auart
LEFT JOIN txt_prioridade tp        ON tp.priok = o.priok
LEFT JOIN txt_atividade ta         ON ta.ilart = o.ilart
LEFT JOIN txt_grupo_plan gp        ON gp.ingrp = o.ingpr
LEFT JOIN status_os so             ON so.aufnr = o.aufnr
LEFT JOIN centro_custo cc          ON cc.kostl = TRIM(COALESCE(o.kostl, ''))
LEFT JOIN centro_lucro cl          ON cl.prctr = TRIM(COALESCE(cc.prctr, ''))
LEFT JOIN imobilizado im           ON im.anln1 = TRIM(COALESCE(o.kostl, ''))
LEFT JOIN aprovacao_reservas ar    ON ar.chave = resb.chave_reserva
LEFT JOIN rsadd                    ON rsadd.rsnum = resb.rsnum AND rsadd.rspos = resb.rspos
LEFT JOIN remessa rem              ON rem.rsnum = resb.rsnum AND rem.rspos = resb.rspos
LEFT JOIN descricao_material dm    ON dm.mat = TRIM(LEADING '0' FROM TRIM(resb.matnr))
LEFT JOIN lotes_ewm_agrupados ewm  ON ewm.material = TRIM(LEADING '0' FROM TRIM(resb.matnr))
LEFT JOIN usuarios_sap uc          ON uc.bname_chave = TRIM(rkpf.usnam)
LEFT JOIN usuarios_sap um          ON um.bname_chave = TRIM(rkpf.lastchangedbyuser);


-- =============================================================================
-- COMPARATIVO ANTES/DEPOIS DOS FILTROS (rode isto uma vez, em homologação)
-- Mostra quantas linhas os dois bugs de NULL estavam escondendo.
-- =============================================================================
-- SELECT
--     count(*) FILTER (WHERE sgtxt IS NULL)                       AS sgtxt_nulo,
--     count(*) FILTER (WHERE xloek IS NULL)                       AS xloek_nulo,
--     count(*) FILTER (WHERE sgtxt IS NULL OR xloek IS NULL)      AS linhas_novas,
--     count(*)                                                    AS total_apos_correcao
-- FROM resb
-- WHERE lgort IN ('D005','D090')
--   AND bwart IN ('201','261')
--   AND sgtxt IS DISTINCT FROM 'Item não estocável'
--   AND xloek IS DISTINCT FROM 'X'
--   AND (postp = 'L' OR postp IS NULL OR postp = '');
