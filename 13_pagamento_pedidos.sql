-- =============================================================================
-- [PATCH r2.2] Datas deste lake são ISO com traço (ex.: 2024-01-02) -> TO_CHAR
-- ajustado para YYYY-MM-DD (com YYYYMMDD o filtro retornava 0 linhas em silêncio).
-- 13_pagamento_pedidos.sql                                   [NACIONAL r2.1]
-- MUDANÇA r2.1 (19/08/2026): filtro de ekgrp/ernam removido — todos os pedidos
-- da janela, com grupo_compras e criado_por_sap como colunas para o app.
-- Substitui : sync_pagamento_pedidos.py -> QUERY
-- Destino   : public.pagamento_pedidos
-- Fonte     : já era nativa (EKKO/EKPO/EKBE)
--
-- Ganho de performance — este é o maior da lista inteira:
--
--   A query antiga fazia EKKO ⋈ EKPO ⋈ EKBE e só então agrupava por EBELN.
--   Mas EKPO só existia ali para fornecer EBELP ao join com EKBE — e o
--   resultado final não usa item nenhum, só responde "este pedido tem fatura
--   lançada?". EKPO costuma ser uma das maiores tabelas do ERP.
--
--   Aqui EKPO sai da query. Sobra: filtrar EKKO (seletivo) e perguntar à EKBE
--   se existe algum documento VGABE='2' para aquele EBELN.
--
--   Além disso não havia NENHUM filtro de data: todo sync varria o histórico
--   completo de pedidos. O parâmetro %(ini)s abaixo resolve isso.
--
-- Diferença de resultado: a versão antiga usava INNER JOIN em EKPO, então um
-- pedido sem item não aparecia. Agora ele aparece como 'Não Lançado'. Se isso
-- for indesejado, descomente o EXISTS de EKPO no fim da CTE `pedidos`.
--
-- Parâmetro: %(ini)s = nº de dias para trás. Use 3650 na carga inicial e
--            algo como 90 nas execuções recorrentes.
-- =============================================================================

WITH pedidos AS (
    -- [NACIONAL r2.1] Filtro de grupo/comprador removido: todos os pedidos da
    -- janela. Separação por grupo/comprador é feita no app pelas colunas novas.
    SELECT k.ebeln, k.ekgrp, k.ernam
    FROM ekko k
    WHERE k.bedat >= TO_CHAR(CURRENT_DATE - %(ini)s::int, 'YYYY-MM-DD')
      -- AND EXISTS (SELECT 1 FROM ekpo p WHERE p.ebeln = k.ebeln)
),

fatura AS (
    SELECT h.ebeln, MAX(h.budat) AS data_pagamento
    FROM ekbe h
    JOIN pedidos p ON p.ebeln = h.ebeln
    WHERE h.vgabe = '2'
    GROUP BY h.ebeln
)

SELECT
    LTRIM(TRIM(p.ebeln), '0') AS pedido,
    NULLIF(TRIM(p.ekgrp), '') AS grupo_compras,   -- [r2.1]
    p.ernam                   AS criado_por_sap,  -- [r2.1]
    CASE WHEN f.ebeln IS NOT NULL
         THEN 'Pago / Fatura Lançada (MIRO)'
         ELSE 'Não Lançado'
    END                       AS status_pagamento,
    f.data_pagamento
FROM pedidos p
LEFT JOIN fatura f ON f.ebeln = p.ebeln
ORDER BY p.ebeln ASC;
