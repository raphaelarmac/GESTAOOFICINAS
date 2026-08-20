-- =============================================================================
-- 05_suprimentos_compras.sql                                 [NACIONAL r2.1]
-- MUDANÇA r2.1 (19/08/2026): filtros de ekgrp/ernam removidos — traz TODAS as
-- requisições/pedidos da janela; app separa por grupo_compras/comprador.
-- ATENÇÃO: sem o filtro de grupo, a janela de data É a única seletividade.
-- Carga inicial: fatiar por período (ex.: ano a ano), não rodar 3650 de uma vez.
-- Recorrente: manter janela curta (ini=30, fim=0).
-- Substitui : sync_patio_total.py -> SUPRIMENTOS_COMPRAS_QUERY   (query 5)
--             sync_compras_rcpc.py -> QUERY                      (query 11)
-- Destino   : public.suprimentos_compras
--
-- As queries 5 e 11 eram a MESMA query, com o mesmo destino, divergindo só em:
--   - a 5 tinha as colunas `num_reserva` (sempre NULL) e `origem` ('compra');
--   - a 5 usava placeholders __DIAS_INICIO__/__DIAS_FIM__ trocados por string,
--     a 11 usava %(ini)s / %(fim)s do psycopg.
-- Aqui elas viram um arquivo só, com as duas colunas extras preservadas e
-- parâmetros nomeados %(ini)s / %(fim)s. Um dos dois scripts Python pode
-- simplesmente deixar de rodar (ver README).
--
-- Parâmetros: %(ini)s e %(fim)s = nº de dias para trás (inteiros).
--             Ex.: ini=30, fim=0  ->  últimos 30 dias.
--
-- Ganhos de performance:
--   1. O recorte de data virou a CTE `rc`, avaliada ANTES de qualquer join.
--      Era o filtro mais seletivo da query e estava no fim, junto de um OR
--      sobre EKKO que impedia o planner de usá-lo cedo.
--   2. Os LATERAL com MAX()/MIN() viraram ORDER BY ... LIMIT 1. Com índice,
--      isso é um index-scan de 1 linha em vez de uma agregação.
--   3. O LATERAL de MAKT (MAX(MAKTX) com SPRAS IN (...)) era executado uma vez
--      por linha da EBAN inteira; agora só roda para os materiais do recorte.
--   4. Sem `%` na query -> nenhuma necessidade de escapar `%%` no psycopg.
--
-- Correção:
--   * `E.BADAT` é texto 'YYYYMMDD' na réplica (por isso o TO_CHAR original).
--     Isso foi mantido de propósito: comparar texto com texto preserva o
--     índice. Se você migrar BADAT para DATE, troque as duas linhas do recorte
--     por comparação com CURRENT_DATE - %(ini)s.
-- =============================================================================

WITH rc AS (
    -- Recorte primeiro: é o filtro mais seletivo da query.
    SELECT
        e.banfn, e.bnfpo, e.matnr, e.txz01, e.menge, e.preis,
        e.ekgrp, e.ernam, e.badat, e.knttp, e.loekz
    FROM eban e
    WHERE e.badat >= TO_CHAR(CURRENT_DATE - %(ini)s::int, 'YYYYMMDD')
      AND e.badat <= TO_CHAR(CURRENT_DATE - %(fim)s::int, 'YYYYMMDD')
      AND TRIM(LEADING '0' FROM TRIM(e.matnr)) <> ''
),

base AS (
    SELECT
        rc.*,
        p.ebeln, p.ebelp, p.menge AS p_menge, p.netpr, p.netwr,
        p.knttp AS p_knttp, p.loekz AS p_loekz,
        k.ekgrp AS k_ekgrp, k.ernam AS k_ernam, k.lifnr, k.bedat, k.frgrl
    FROM rc
    LEFT JOIN ekpo p ON p.banfn = rc.banfn AND p.bnfpo = rc.bnfpo
    LEFT JOIN ekko k ON k.ebeln = p.ebeln
    -- [NACIONAL r2.1] Filtro de grupo de compras / comprador REMOVIDO:
    -- o pipeline entrega TUDO na janela de data; a separação por grupo/
    -- comprador é feita no app, pelas colunas grupo_compras / comprador /
    -- criado_por_sap. A seletividade agora é 100% da janela %(ini)s/%(fim)s.
)

SELECT
    COALESCE(NULLIF(TRIM(LEADING '0' FROM TRIM(a.equnr)), ''), 'ESTOQUE') AS ativo,

    COALESCE(
        NULLIF(TRIM(LEADING '0' FROM TRIM(acc.aufnr)), ''),
        NULLIF('PC-' || TRIM(LEADING '0' FROM TRIM(COALESCE(b.ebeln, ''))), 'PC-'),
        'RC-' || TRIM(LEADING '0' FROM TRIM(b.banfn))
    ) AS ordem,

    TRIM(LEADING '0' FROM TRIM(b.matnr))                  AS cod_sap,
    COALESCE(m.maktx, b.txz01)                            AS descricao,
    COALESCE(b.p_menge, b.menge)                          AS qtd_req,
    NULLIF(TRIM(LEADING '0' FROM TRIM(COALESCE(b.ebeln, ''))), '') AS pedido,
    NULL::varchar                                         AS num_reserva,
    'compra'::text                                        AS origem,
    TRIM(COALESCE(b.ebelp::varchar, b.bnfpo::varchar))    AS num_operacao,
    NULLIF(TRIM(LEADING '0' FROM TRIM(b.banfn)), '')      AS num_rc,
    b.bnfpo::varchar                                      AS item_rc,
    COALESCE(b.k_ernam, b.ekgrp)                          AS comprador,
    COALESCE(NULLIF(TRIM(b.k_ekgrp), ''), b.ekgrp)        AS grupo_compras,  -- [r2.1]
    b.ernam                                               AS criado_por_sap,
    b.badat                                               AS data_requisicao,
    NULLIF(TRIM(LEADING '0' FROM TRIM(COALESCE(b.lifnr, ''))), '') AS fornecedor_cod,
    vend.name1                                            AS fornecedor_nome,
    b.bedat                                               AS data_emissao_pc,
    sch.eindt                                             AS data_remessa_pc,
    COALESCE(b.netpr, b.preis)                            AS vlr_unit,
    COALESCE(b.netwr, b.menge * b.preis)                  AS vlr_total,

    NULLIF(TRIM(COALESCE(b.p_knttp, b.knttp, '')), '')    AS knttp,

    CASE
        WHEN COALESCE(TRIM(COALESCE(b.p_knttp, b.knttp, '')), '') = '' THEN 'estoque'
        WHEN TRIM(COALESCE(b.p_knttp, b.knttp)) = 'K'                  THEN 'centro_custo'
        ELSE 'consumo'
    END AS destinacao,

    CASE TRIM(COALESCE(b.p_knttp, b.knttp, ''))
        WHEN 'K' THEN 'Centro de Custo'
        WHEN 'A' THEN 'Ativo Fixo (Imobilizado)'
        WHEN 'F' THEN 'Ordem (Manutencao/Interna)'
        WHEN 'P' THEN 'Projeto (PEP)'
        WHEN 'Q' THEN 'Projeto (PEP)'
        WHEN 'N' THEN 'Rede'
        WHEN ''  THEN 'Estoque'
        ELSE 'Outro'
    END AS tipo_consumo,

    NULLIF(TRIM(LEADING '0' FROM TRIM(COALESCE(pk.kostl, acc.kostl, ''))), '') AS centro_custo,

    CASE
        WHEN COALESCE(h.qtd_recebida, 0) >= b.p_menge AND b.p_menge > 0 THEN 'recebido'
        WHEN COALESCE(h.qtd_recebida, 0) > 0                            THEN 'entrega_parcial'
        WHEN b.frgrl = 'X'                                              THEN 'aguardando_aprovacao'
        WHEN b.ebeln IS NOT NULL
         AND COALESCE(TRIM(b.p_loekz), '') <> 'L'                       THEN 'pedido_emitido'
        WHEN TRIM(COALESCE(b.p_loekz, '')) = 'L'                        THEN 'pedido_cancelado'
        WHEN TRIM(COALESCE(b.loekz, '')) = 'X'                          THEN 'rc_excluida'
        WHEN b.banfn IS NOT NULL
         AND COALESCE(TRIM(b.ebeln), '') = ''                           THEN 'aguardando_pedido'
        ELSE 'verificar'
    END AS status_processo

FROM base b

LEFT JOIN LATERAL (
    SELECT n.aufnr, n.kostl
    FROM ebkn n
    WHERE n.banfn = b.banfn AND n.bnfpo = b.bnfpo
    ORDER BY n.aufnr DESC NULLS LAST
    LIMIT 1
) acc ON TRUE

LEFT JOIN LATERAL (
    SELECT n.kostl
    FROM ekkn n
    WHERE n.ebeln = b.ebeln AND n.ebelp = b.ebelp
    ORDER BY n.kostl DESC NULLS LAST
    LIMIT 1
) pk ON TRUE

LEFT JOIN afih a  ON a.aufnr = acc.aufnr
LEFT JOIN lfa1 vend ON vend.lifnr = b.lifnr

LEFT JOIN LATERAL (
    SELECT SUM(x.menge) AS qtd_recebida
    FROM ekbe x
    WHERE x.ebeln = b.ebeln AND x.ebelp = b.ebelp AND x.vgabe = '1'
) h ON TRUE

LEFT JOIN LATERAL (
    SELECT x.eindt
    FROM eket x
    WHERE x.ebeln = b.ebeln AND x.ebelp = b.ebelp
    ORDER BY x.eindt
    LIMIT 1
) sch ON TRUE

LEFT JOIN LATERAL (
    SELECT x.maktx
    FROM makt x
    WHERE x.matnr = b.matnr AND lower(x.spras) IN ('p', 'pt')
    ORDER BY x.spras
    LIMIT 1
) m ON TRUE

ORDER BY b.banfn ASC;
