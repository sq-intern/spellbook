{{ config(
    alias = 'bot_trades',
    schema = 'tradewiz',
    partition_by = ['block_month'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.block_time')],
    unique_key = ['blockchain', 'tx_id', 'tx_index', 'outer_instruction_index', 'inner_instruction_index']
   )
}}

{% set project_start_date = '2024-11-27' %}
{% set fee_receiver_1 = '97VmzkjX9w8gMFS2RnHTSjtMEDbifGXBq9pgosFdFnM' %}
{% set wsol_token = 'So11111111111111111111111111111111111111112' %}

WITH
  allFeePayments AS (
    SELECT
      tx_id,
      'SOL' AS feeTokenType,
      balance_change / 1e9 AS fee_token_amount,
      '{{wsol_token}}' AS fee_token_mint_address
    FROM
      {{ source('solana','account_activity') }}
    WHERE
      {% if is_incremental() %}
      {{ incremental_predicate('block_time') }}
      {% else %}
      block_time >= TIMESTAMP '{{project_start_date}}'
      {% endif %}
      AND tx_success
      AND balance_change > 0
      AND (
        address = '{{fee_receiver_1}}'
      )
  ),
  botTrades AS (
    SELECT
      trades.block_time,
      CAST(date_trunc('day', trades.block_time) AS date) AS block_date,
      CAST(date_trunc('month', trades.block_time) AS date) AS block_month,
      'solana' AS blockchain,
      amount_usd,
      IF(
        token_sold_mint_address = '{{wsol_token}}',
        'Buy',
        'Sell'
      ) AS type,
      token_bought_amount,
      token_bought_symbol,
      token_bought_mint_address AS token_bought_address,
      token_sold_amount,
      token_sold_symbol,
      token_sold_mint_address AS token_sold_address,
      fee_token_amount * price AS fee_usd,
      fee_token_amount,
      IF(feeTokenType = 'SOL', 'SOL', symbol) AS fee_token_symbol,
      fee_token_mint_address AS fee_token_address,
      project,
      trades.version,
      token_pair,
      project_program_id AS project_contract_address,
      trader_id AS user,
      trades.tx_id,
      tx_index,
      outer_instruction_index,
      inner_instruction_index
    FROM
      {{ source('dex_solana', 'trades') }} AS trades
      JOIN allFeePayments AS feePayments ON trades.tx_id = feePayments.tx_id
      LEFT JOIN {{ source('prices', 'usd') }} AS feeTokenPrices ON (
        feeTokenPrices.blockchain = 'solana'
        AND fee_token_mint_address = toBase58 (feeTokenPrices.contract_address)
        AND date_trunc('minute', block_time) = minute
        {% if is_incremental() %}
        AND {{ incremental_predicate('minute') }}
        {% else %}
        AND minute >= TIMESTAMP '{{project_start_date}}'
        {% endif %}
      )
      JOIN {{ source('solana','transactions') }} AS transactions ON (
        trades.tx_id = id
        {% if is_incremental() %}
        AND {{ incremental_predicate('transactions.block_time') }}
        {% else %}
        AND transactions.block_time >= TIMESTAMP '{{project_start_date}}'
        {% endif %}
      )
    WHERE
      trades.trader_id != '{{fee_receiver_1}}' -- Exclude trades signed by FeeWallet
      AND transactions.signer != '{{fee_receiver_1}}' -- Exclude trades signed by FeeWallet
      {% if is_incremental() %}
      AND {{ incremental_predicate('trades.block_time') }}
      {% else %}
      AND trades.block_time >= TIMESTAMP '{{project_start_date}}'
      {% endif %}
  ),
  highestInnerInstructionIndexForEachTrade AS (
    SELECT
      tx_id,
      outer_instruction_index,
      MAX(inner_instruction_index) AS highestInnerInstructionIndex
    FROM
      botTrades
    GROUP BY
      tx_id,
      outer_instruction_index
  )
SELECT
  block_time,
  block_date,
  block_month,
  'Tradewiz' as bot,
  blockchain,
  amount_usd,
  type,
  token_bought_amount,
  token_bought_symbol,
  token_bought_address,
  token_sold_amount,
  token_sold_symbol,
  token_sold_address,
  fee_usd,
  fee_token_amount,
  fee_token_symbol,
  fee_token_address,
  project,
  version,
  token_pair,
  project_contract_address,
  user,
  botTrades.tx_id,
  tx_index,
  botTrades.outer_instruction_index,
  COALESCE(inner_instruction_index, 0) AS inner_instruction_index,
  IF(
    inner_instruction_index = highestInnerInstructionIndex,
    true,
    false
  ) AS is_last_trade_in_transaction
FROM
  botTrades
  JOIN highestInnerInstructionIndexForEachTrade ON (
    botTrades.tx_id = highestInnerInstructionIndexForEachTrade.tx_id
    AND botTrades.outer_instruction_index = highestInnerInstructionIndexForEachTrade.outer_instruction_index
  )
ORDER BY
  block_time DESC,
  tx_index DESC,
  outer_instruction_index DESC,
  inner_instruction_index DESC
