-- 06_uca_patio.sql — VARIANTE MySQL 8 [NACIONAL r2]
-- Use esta se a fonte for o MySQL da ARMAC (db fastfield), como no sync_uca.py.
-- Mesma semântica da versão Postgres: último evento GLOBAL por ativo;
-- se for Entrada, o ativo está no pátio da filial daquele evento.
WITH ultimo AS (
    SELECT r.*,
           ROW_NUMBER() OVER (PARTITION BY r.n_armac
                              ORDER BY r.created_at_form DESC) AS rn
    FROM fastfield.relatorio_entrada_saida_uca r
    WHERE r.n_armac IS NOT NULL
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
WHERE u.rn = 1
  AND u.tipo_relatorio = 'Entrada';
