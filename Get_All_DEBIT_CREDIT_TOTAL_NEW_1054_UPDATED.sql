SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[Get_All_DEBIT_CREDIT_TOTAL_NEW_1054]
    @CompanyCode        BIGINT,
    @CustomerCodes      NVARCHAR(MAX),
    @Document_Type      NVARCHAR(50) = NULL,
    @FinancialYear      NVARCHAR(10) = NULL,
    @CreditControlArea  NVARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @CustomerCodes IS NOT NULL
       AND LTRIM(RTRIM(@CustomerCodes)) = ''
        SET @CustomerCodes = NULL;

    IF @Document_Type IS NOT NULL
       AND LTRIM(RTRIM(@Document_Type)) = ''
        SET @Document_Type = NULL;

    IF @FinancialYear IS NOT NULL
       AND LTRIM(RTRIM(@FinancialYear)) = ''
        SET @FinancialYear = NULL;

    ----------------------------------------------------------------------
    -- For CompanyCode 1054:
    -- UI document type OP maps to SAP/database document type AB.
    ----------------------------------------------------------------------
    IF UPPER(LTRIM(RTRIM(ISNULL(@Document_Type, '')))) = 'OP'
        SET @Document_Type = 'AB';

    DECLARE @FromDate DATE = NULL;
    DECLARE @ToDate DATE = NULL;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    ----------------------------------------------------------------------
    -- Financial year
    ----------------------------------------------------------------------
    IF @FinancialYear IS NOT NULL
    BEGIN
        DECLARE @StartYear INT = TRY_CAST(LEFT(@FinancialYear, 4) AS INT);

        IF @StartYear IS NOT NULL
        BEGIN
            DECLARE @EndYear INT = @StartYear + 1;

            SET @FromDate = DATEFROMPARTS(@StartYear, 4, 1);
            SET @ToDate = DATEFROMPARTS(@EndYear, 3, 31);

            IF @ToDate > @Today
                SET @ToDate = @Today;
        END
    END

    ----------------------------------------------------------------------
    -- Default: current FY start to today
    ----------------------------------------------------------------------
    IF @FromDate IS NULL AND @ToDate IS NULL
    BEGIN
        DECLARE @FYStartYear INT =
            CASE
                WHEN MONTH(@Today) >= 4 THEN YEAR(@Today)
                ELSE YEAR(@Today) - 1
            END;

        SET @FromDate = DATEFROMPARTS(@FYStartYear, 4, 1);
        SET @ToDate = @Today;
    END

    IF @FromDate IS NULL
        SET @FromDate = '19000101';

    IF @ToDate IS NULL
        SET @ToDate = @Today;

    ----------------------------------------------------------------------
    -- Allowed customers
    ----------------------------------------------------------------------
    DECLARE @Allowed TABLE
    (
        CustomerCode NVARCHAR(50) PRIMARY KEY
    );

    IF @CustomerCodes IS NOT NULL
    BEGIN
        INSERT INTO @Allowed(CustomerCode)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@CustomerCodes, ',')
        WHERE LTRIM(RTRIM(value)) <> '';
    END

    DECLARE @TotalDebitAmount   DECIMAL(18,2) = 0;
    DECLARE @TotalCreditAmount  DECIMAL(18,2) = 0;
    DECLARE @TotalClosingAmount DECIMAL(18,2) = 0;
    DECLARE @OpeningBalance     DECIMAL(18,2) = 0;
    DECLARE @FallbackOpening    DECIMAL(18,2) = 0;

    ----------------------------------------------------------------------
    -- Latest AB per Customer + Credit Control Area.
    --
    -- Example:
    -- 31-03-2026 AB       2,93,188
    -- 01-09-2026 AB    1,42,93,288
    --
    -- Latest applicable AB = 01-09-2026
    ----------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#LatestAB') IS NOT NULL
        DROP TABLE #LatestAB;

    ;WITH ABRows AS
    (
        SELECT
            L.CustomerCode,
            L.Credit_Control_Area,
            L.Document_Date,
            L.Amount_in_Local_Currency,
            ROW_NUMBER() OVER
            (
                PARTITION BY
                    L.CustomerCode,
                    L.Credit_Control_Area
                ORDER BY
                    L.Document_Date DESC,
                    L.Posting_Date DESC,
                    L.Document_Number DESC
            ) AS RN
        FROM dbo.TB_CustomerLedger AS L
        WHERE L.CompanyCode = @CompanyCode
          AND @CompanyCode = 1054
          AND L.Document_Type = 'AB'
          AND L.Document_Date <= @ToDate
          AND
          (
              @CreditControlArea IS NULL
              OR L.Credit_Control_Area = @CreditControlArea
          )
          AND
          (
              @CustomerCodes IS NULL
              OR EXISTS
              (
                  SELECT 1
                  FROM @Allowed A
                  WHERE A.CustomerCode = L.CustomerCode
              )
          )
    )
    SELECT
        CustomerCode,
        Credit_Control_Area,
        Document_Date AS ABDate,
        Amount_in_Local_Currency AS OpeningAmount
    INTO #LatestAB
    FROM ABRows
    WHERE RN = 1;

    ----------------------------------------------------------------------
    -- AB is the Opening Balance.
    -- Take latest AB amount directly.
    -- Do NOT put AB into Debit or Credit totals again.
    ----------------------------------------------------------------------
    SELECT
        @OpeningBalance =
            ISNULL(SUM(OpeningAmount), 0)
    FROM #LatestAB;

    ----------------------------------------------------------------------
    -- Fallback for existing 1054 customers that do not have AB.
    -- Keep the previous historical-opening logic for those customers.
    ----------------------------------------------------------------------
    SELECT
        @FallbackOpening =
              ISNULL
              (
                  SUM
                  (
                      CASE
                          WHEN L.Amount_in_Local_Currency >= 0
                              THEN L.Amount_in_Local_Currency
                          ELSE 0
                      END
                  ),
                  0
              )
            -
              ISNULL
              (
                  SUM
                  (
                      CASE
                          WHEN L.Amount_in_Local_Currency < 0
                              THEN ABS(L.Amount_in_Local_Currency)
                          ELSE 0
                      END
                  ),
                  0
              )
    FROM dbo.TB_CustomerLedger AS L
    WHERE L.CompanyCode = @CompanyCode
      AND @CompanyCode = 1054
      AND
      (
          @CreditControlArea IS NULL
          OR L.Credit_Control_Area = @CreditControlArea
      )
      AND L.Document_Date < @FromDate
      AND L.Document_Type IN ('RV', 'DC', 'DZ')
      AND
      (
          @CustomerCodes IS NULL
          OR EXISTS
          (
              SELECT 1
              FROM @Allowed A
              WHERE A.CustomerCode = L.CustomerCode
          )
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM #LatestAB AB
          WHERE AB.CustomerCode = L.CustomerCode
            AND ISNULL(AB.Credit_Control_Area, '') =
                ISNULL(L.Credit_Control_Area, '')
      )
      AND
      (
          @Document_Type IS NULL
          OR L.Document_Type = @Document_Type
      )
      AND
      (
          @Document_Type IS NULL
          OR
          (
              (@Document_Type = 'RV'
               AND L.Amount_in_Local_Currency >= 0)
              OR
              (@Document_Type = 'DZ'
               AND L.Amount_in_Local_Currency < 0)
              OR
              (@Document_Type = 'DC')
              OR
              (@Document_Type NOT IN ('RV', 'DZ', 'DC'))
          )
      );

    SET @OpeningBalance =
        ISNULL(@OpeningBalance, 0) + ISNULL(@FallbackOpening, 0);

    ----------------------------------------------------------------------
    -- Current period Debit / Credit.
    --
    -- AB is excluded from Debit/Credit.
    --
    -- If the latest AB is inside the selected FY, normal transactions
    -- before/on that AB date are not counted again because AB is treated
    -- as the new opening snapshot.
    --
    -- If AB is before the selected FY, normal FY transactions are counted
    -- from @FromDate as before.
    ----------------------------------------------------------------------
    SELECT
        @TotalDebitAmount =
            ISNULL
            (
                SUM
                (
                    CASE
                        WHEN L.DC = 'S'
                            THEN L.Amount_in_Local_Currency
                        ELSE 0
                    END
                ),
                0
            ),

        @TotalCreditAmount =
            ISNULL
            (
                SUM
                (
                    CASE
                        WHEN L.DC = 'H'
                            THEN L.Amount_in_Local_Currency
                        ELSE 0
                    END
                ),
                0
            )
    FROM dbo.TB_CustomerLedger AS L
    LEFT JOIN #LatestAB AS AB
        ON AB.CustomerCode = L.CustomerCode
       AND ISNULL(AB.Credit_Control_Area, '') =
           ISNULL(L.Credit_Control_Area, '')
    WHERE L.CompanyCode = @CompanyCode
      AND @CompanyCode = 1054
      AND
      (
          @CreditControlArea IS NULL
          OR L.Credit_Control_Area = @CreditControlArea
      )
      AND L.Document_Date >= @FromDate
      AND L.Document_Date <= @ToDate

      -- AB/OP is Opening Balance only, never Debit/Credit total.
      AND L.Document_Type IN ('RV', 'DC', 'DZ')

      AND
      (
          @CustomerCodes IS NULL
          OR EXISTS
          (
              SELECT 1
              FROM @Allowed A
              WHERE A.CustomerCode = L.CustomerCode
          )
      )

      -- If AB is inside the FY, only transactions AFTER that AB are used.
      AND
      (
          AB.ABDate IS NULL
          OR AB.ABDate < @FromDate
          OR L.Document_Date > AB.ABDate
      )

      AND
      (
          @Document_Type IS NULL
          OR
          (
              @Document_Type <> 'AB'
              AND L.Document_Type = @Document_Type
          )
      );

    ----------------------------------------------------------------------
    -- When OP/AB is explicitly selected:
    -- only Opening Balance is relevant.
    ----------------------------------------------------------------------
    IF @Document_Type = 'AB'
    BEGIN
        SET @TotalDebitAmount = 0;
        SET @TotalCreditAmount = 0;
    END

    ----------------------------------------------------------------------
    -- Closing Balance
    --
    -- Closing = Opening + Debit - Credit
    ----------------------------------------------------------------------
    SET @TotalClosingAmount =
          @OpeningBalance
        + @TotalDebitAmount
        - @TotalCreditAmount;

    SELECT
        @TotalDebitAmount   AS TotalDebitAmount,
        @TotalCreditAmount  AS TotalCreditAmount,
        @TotalClosingAmount AS ClosingBalance,
        @OpeningBalance     AS OpeningBalanceTotal;

    DROP TABLE #LatestAB;
END
GO
