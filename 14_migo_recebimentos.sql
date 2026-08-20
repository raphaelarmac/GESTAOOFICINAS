-- =============================================================================
-- 14_migo_recebimentos.sql
-- Substitui : sync_migo.py -> QUERY
-- Destino   : public.migo_recebimentos
-- Fonte     : tabelas do app interno (não é SAP) - mantida
--
-- Query já era enxuta. Mudanças:
--   1. A CTE `main` foi eliminada: era só uma projeção, e o CASE do SELECT
--      externo podia ser calculado no mesmo nível.
--   2. `TRIM(LEADING '0' FROM ...)` sobre um COALESCE que pode devolver ''
--      resultava em string vazia em vez de NULL. Agora sai NULL, que é o que
--      o destino espera para "sem requisição".
--   3. ORDER BY: mantido o comportamento original (status_migo ASC coloca
--      'MIGO FEITA' antes de 'MIGO PENDENTE', por ordem alfabética).
--      Adicionado NULLS LAST na data para as pendentes não subirem.
-- =============================================================================

SELECT
    er.pedido,
    NULLIF(
        TRIM(LEADING '0' FROM COALESCE(NULLIF(er.requisicao_de_compra_os, ''),
                                       rc.numero_pedido_gerado,
                                       '')),
        ''
    )                                    AS requisicao,
    er.data_recebimento                  AS data_do_recebimento_fisico,
    CASE WHEN er.data_recebimento IS NOT NULL
         THEN 'MIGO FEITA'
         ELSE 'MIGO PENDENTE'
    END                                  AS status_migo
FROM evidencia_recebimentos er
LEFT JOIN requisicoes_de_compra rc ON rc.id = er.requisicao_de_compra_id
ORDER BY status_migo ASC, er.data_recebimento DESC NULLS LAST;
