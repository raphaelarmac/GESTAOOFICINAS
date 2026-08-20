-- =============================================================================
-- 14_migo_recebimentos.sql — DIALETO MySQL 8                  [PATCH r2.5]
-- Substitui : sync_migo.py -> QUERY
-- Fonte     : MySQL (conexão MIGO_DB_*), tabelas do app interno
--
-- Traduções vs. a versão Postgres original:
--   * NULLS LAST não existe no MySQL -> ORDER BY (col IS NULL), col DESC
--     (o booleano ordena os NULLs por último, mesmo efeito).
--   * TRIM(LEADING '0' FROM ...) e NULLIF/COALESCE são idênticos nos dois.
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
ORDER BY status_migo ASC,
         (er.data_recebimento IS NULL),   -- NULLs por último (equivalente ao NULLS LAST)
         er.data_recebimento DESC;
