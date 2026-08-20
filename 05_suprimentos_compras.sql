-- =============================================================================
-- [PATCH r2.2] Datas deste lake são ISO com traço (ex.: 2024-01-02) -> TO_CHAR
-- ajustado para YYYY-MM-DD (com YYYYMMDD o filtro retornava 0 linhas em silêncio).
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
--   4. Query sem curingas LIKE -> nada a escapar para o psycopg.
--
-- Correção:
--   * `E.BADAT` é texto 'YYYY-MM-DD' na réplica (por isso o TO_CHAR original).
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
    WHERE e.badat >= TO_CHAR(CURRENT_DATE - %(ini)s::int, 'YYYY-MM-DD')
      AND e.badat <= TO_CHAR(CURRENT_DATE - %(fim)s::int, 'YYYY-MM-DD')
      AND TRIM(LEADING '0' FROM TRIM(e.matnr)) <> ''
      -- [OTIM r2.9] Escopo da oficina POR CENTRO (werks vem sempre preenchido
      -- na EBAN; o depósito não). Mapa VIVO via T001L: os centros são os donos
      -- dos depósitos de separação — filial nova que adotar um desses códigos
      -- de depósito entra sozinha, sem editar a query.
      -- (Hoje: C002 Rondonópolis, C005 Ouro Preto, C006 BH, C007 CDP,
      --  C013 Feira de Santana, C019 SJ dos Pinhais.)
      -- Comprador/grupo seguem como COLUNAS — recorte por comprador é do app.
      AND e.werks IN (
            SELECT DISTINCT l.werks
            FROM t001l l
            WHERE l.lgort IN ('D005', 'D090', 'D007', 'D002', 'D123', 'D071')
      )
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
    -- criado_por_sap. A seletividade agora vem toda da janela de datas.
),

-- ============================================================================
-- [OTIM r3.0] LATERALs substituídos por lookups agregados: cada tabela grande
-- é lida UMA única vez (com filtro barato) e casada por hash join — antes,
-- sem índice na réplica, cada linha da base varria EBKN/EKKN/EKBE/EKET/MAKT
-- inteiras de novo (milhares de varreduras completas por execução).
-- ============================================================================
chaves_pedido AS (
    SELECT DISTINCT ebeln, ebelp FROM base WHERE ebeln IS NOT NULL
),

acc AS (  -- conta contábil da RC (maior aufnr do item)
    SELECT DISTINCT ON (n.banfn, n.bnfpo) n.banfn, n.bnfpo, n.aufnr, n.kostl
    FROM ebkn n
    JOIN rc ON rc.banfn = n.banfn AND rc.bnfpo = n.bnfpo
    ORDER BY n.banfn, n.bnfpo, n.aufnr DESC NULLS LAST
),

pk AS (   -- conta contábil do pedido
    SELECT DISTINCT ON (n.ebeln, n.ebelp) n.ebeln, n.ebelp, n.kostl
    FROM ekkn n
    JOIN chaves_pedido cp ON cp.ebeln = n.ebeln AND cp.ebelp = n.ebelp
    ORDER BY n.ebeln, n.ebelp, n.kostl DESC NULLS LAST
),

receb AS (  -- quantidade recebida (EKBE vgabe=1); budat >= início da janela
            -- (recebimento nunca antecede a criação da RC/pedido da janela)
    SELECT x.ebeln, x.ebelp, SUM(x.menge) AS qtd_recebida
    FROM ekbe x
    JOIN chaves_pedido cp ON cp.ebeln = x.ebeln AND cp.ebelp = x.ebelp
    WHERE x.vgabe = '1'
      AND x.budat >= TO_CHAR(CURRENT_DATE - %(ini)s::int, 'YYYY-MM-DD')
    GROUP BY x.ebeln, x.ebelp
),

sch AS (   -- primeira data de remessa programada (EKET)
    SELECT DISTINCT ON (x.ebeln, x.ebelp) x.ebeln, x.ebelp, x.eindt
    FROM eket x
    JOIN chaves_pedido cp ON cp.ebeln = x.ebeln AND cp.ebelp = x.ebelp
    ORDER BY x.ebeln, x.ebelp, x.eindt
),

m AS (     -- descrição de material em PT
    SELECT DISTINCT ON (x.matnr) x.matnr, x.maktx
    FROM makt x
    JOIN (SELECT DISTINCT matnr FROM rc) mats ON mats.matnr = x.matnr
    WHERE lower(x.spras) IN ('p', 'pt')
    ORDER BY x.matnr, lower(x.spras)
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
LEFT JOIN acc      ON acc.banfn = b.banfn AND acc.bnfpo = b.bnfpo
LEFT JOIN pk       ON pk.ebeln  = b.ebeln AND pk.ebelp  = b.ebelp
LEFT JOIN afih a   ON a.aufnr   = acc.aufnr
LEFT JOIN lfa1 vend ON vend.lifnr = b.lifnr
LEFT JOIN receb h  ON h.ebeln   = b.ebeln AND h.ebelp   = b.ebelp
LEFT JOIN sch      ON sch.ebeln = b.ebeln AND sch.ebelp = b.ebelp
LEFT JOIN m        ON m.matnr   = b.matnr

ORDER BY b.banfn ASC;
