-- =============================================================================
-- 06_uca_patio.sql                                           [NACIONAL r2]
-- Substitui : sync_patio_total.py -> UCA_QUERY
-- Destino   : public.uca_records
-- Fonte     : fastfield (app de campo, não é SAP) - mantida
--
-- MUDANÇAS r2 (escopo nacional, 19/08/2026):
--   * Filtro de filial BH REMOVIDO. A filial vira coluna.
--   * Semântica nacional do "pátio atual": o último evento de cada ativo é
--     calculado GLOBALMENTE (a máquina só está em um lugar por vez). Se o
--     último evento é Entrada, o ativo está no pátio da filial daquele
--     evento; se é Saída, está fora de qualquer pátio e não aparece aqui.
--     Isso torna o comportamento que antes era caso de borda ("entrou em
--     outra filial e sumiu da lista de BH") o comportamento CORRETO:
--     ele agora aparece na lista, na filial certa.
--   * DISTINCT ON mantido; usa o índice ix_uca_armac_data do 99.
-- =============================================================================

WITH ultimo AS (
    SELECT DISTINCT ON (r.n_armac)
        r.n_armac,
        r.tipo_relatorio,
        r.tipo_equipamento,
        r.marca,
        r.modelo,
        r.cliente,
        r.situacao,
        r.created_at_form,
        r.horimetro,
        r.filial
    FROM fastfield.relatorio_entrada_saida_uca r
    WHERE r.n_armac IS NOT NULL
    ORDER BY r.n_armac, r.created_at_form DESC
)
SELECT
    UPPER(TRIM(u.n_armac))   AS n_armac,
    u.tipo_equipamento       AS equipamento,
    UPPER(TRIM(u.marca))     AS marca,
    UPPER(TRIM(u.modelo))    AS modelo,
    u.cliente                AS cliente,
    u.situacao               AS situacao,
    u.created_at_form        AS data_entrada,
    u.horimetro              AS horimetro,
    u.filial                 AS filial
FROM ultimo u
WHERE u.tipo_relatorio = 'Entrada';
