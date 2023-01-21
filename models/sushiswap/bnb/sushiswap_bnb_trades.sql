{{ config(
    alias = 'trades'
    ,partition_by = ['block_date']
    ,materialized = 'incremental'
    ,file_format = 'delta'
    ,incremental_strategy = 'merge'
    ,unique_key = ['block_date', 'blockchain', 'project', 'version', 'tx_hash', 'evt_index', 'trace_address']
    ,post_hook='{{ expose_spells(\'["bnb"]\',
                                      "project",
                                      "sushiswap",
                                    \'["hosuke","codingsh"]\') }}'
    )
}}

{% set project_start_date = '2021-03-03' %}

WITH sushiswap_dex AS (
    SELECT t.evt_block_time                                                   AS block_time,
           t.to                                                               AS taker,
           ''                                                                 AS maker,
           case when t.amount0Out = 0 then t.amount1Out else t.amount0Out end AS token_bought_amount_raw,
           case when t.amount0In = 0 then t.amount1In else t.amount0In end    AS token_sold_amount_raw,
           cast(NULL AS double)                                               AS amount_usd,
           case when t.amount0Out = 0 then f.token1 else f.token0 end         AS token_bought_address,
           case when t.amount0In = 0 then f.token1 else f.token0 end          AS token_sold_address,
           t.contract_address                                                 AS project_contract_address,
           t.evt_tx_hash                                                      AS tx_hash,
           ''                                                                 AS trace_address,
           t.evt_index
    FROM {{ source('sushi_bnb', 'UniswapV2Router02_evt_swapTokensForExactTokens') }} t
    INNER JOIN {{ source('sushi_bnb', 'UniswapV2Factory_evt_PairCreated') }} f
        ON f.pair = t.contract_address
    {% if is_incremental() %}
    WHERE t.evt_block_time >= date_trunc("day", now() - interval '1 week')
    {% endif %}
    {% if not is_incremental() %}
    WHERE t.evt_block_time >= '{{ project_start_date }}'
    {% endif %}
)

SELECT
    'bnb'                                                              AS blockchain,
    'sushiswap'                                                        AS project,
    '1'                                                                AS version,
    try_cast(date_trunc('DAY', sushiswap_dex.block_time) AS date)      AS block_date,
    sushiswap_dex.block_time,
    erc20a.symbol                                                      AS token_bought_symbol,
    erc20b.symbol                                                      AS token_sold_symbol,
     CASE
        WHEN lower(erc20a.symbol) > lower(erc20b.symbol) THEN concat(erc20b.symbol, '-', erc20a.symbol)
        ELSE concat(erc20a.symbol, '-', erc20b.symbol)
        END                                                            AS token_pair,
    sushiswap_dex.token_bought_amount_raw / power(10, erc20a.decimals) AS token_bought_amount,
    sushiswap_dex.token_sold_amount_raw / power(10, erc20b.decimals)   AS token_sold_amount,
    CAST(sushiswap_dex.token_bought_amount_raw AS DECIMAL(38, 0))      AS token_bought_amount_raw,
    CAST(sushiswap_dex.token_sold_amount_raw AS DECIMAL(38, 0))        AS token_sold_amount_raw,
    coalesce(
            sushiswap_dex.amount_usd
        , (sushiswap_dex.token_bought_amount_raw / power(10, p_bought.decimals)) * p_bought.price
        , (sushiswap_dex.token_sold_amount_raw / power(10, p_sold.decimals)) * p_sold.price
        )                                                              AS amount_usd,
    sushiswap_dex.token_bought_address,
    sushiswap_dex.token_sold_address,
    coalesce(sushiswap_dex.taker, tx.from)                             AS taker,
    sushiswap_dex.maker,
    sushiswap_dex.project_contract_address,
    sushiswap_dex.tx_hash,
    tx.from                                                            AS tx_from,
    tx.to                                                              AS tx_to,
    sushiswap_dex.trace_address,
    sushiswap_dex.evt_index
FROM sushiswap_dex
INNER JOIN {{ source('bnb', 'transactions') }} tx
    ON sushiswap_dex.tx_hash = tx.hash
    {% if not is_incremental() %}
    AND tx.block_time >= '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND tx.block_time >= date_trunc("day", now() - interval '1 week')
    {% endif %}
LEFT JOIN {{ ref('tokens_erc20') }} erc20a
    ON erc20a.contract_address = sushiswap_dex.token_bought_address
    AND erc20a.blockchain = 'bnb'
LEFT JOIN {{ ref('tokens_erc20') }} erc20b
    ON erc20b.contract_address = sushiswap_dex.token_sold_address
    AND erc20b.blockchain = 'bnb'
LEFT JOIN {{ source('prices', 'usd') }} p_bought
    ON p_bought.minute = date_trunc('minute', sushiswap_dex.block_time)
    AND p_bought.contract_address = sushiswap_dex.token_bought_address
    AND p_bought.blockchain = 'bnb'
    {% if not is_incremental() %}
    AND p_bought.minute >= '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p_bought.minute >= date_trunc("day", now() - interval '1 week')
    {% endif %}
LEFT JOIN {{ source('prices', 'usd') }} p_sold
    ON p_sold.minute = date_trunc('minute', sushiswap_dex.block_time)
    AND p_sold.contract_address = sushiswap_dex.token_sold_address
    AND p_sold.blockchain = 'bnb'
    {% if not is_incremental() %}
    AND p_sold.minute >= '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p_sold.minute >= date_trunc("day", now() - interval '1 week')
    {% endif %}
;
    