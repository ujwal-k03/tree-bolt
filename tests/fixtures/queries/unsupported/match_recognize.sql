SELECT *
FROM stock_prices
MATCH_RECOGNIZE (
    ORDER BY trade_date
    MEASURES A.price AS start_price
    PATTERN (A B+)
    SUBSET U = (A, B)
    DEFINE B AS B.price > PREV(B.price)
)