SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[Get_All_CustomerLedgers_1054]
    @CompanyCode        BIGINT,
    @CustomerCodes      NVARCHAR(MAX),
    @Document_Type      NVARCHAR(50) = NULL,
    @CreditControlArea  NVARCHAR(10) = NULL,
    @FinancialYear      NVARCHAR(10) = NULL,
    @Offset             INT,
    @PageSize           INT
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
    -- Database/SAP stores opening balance document type as AB.
    -- UI/API will expose it as OP.
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

    DECLARE @ToDateNextDay DATE = DATEADD(DAY, 1, @ToDate);

    ----------------------------------------------------------------------
    -- Materialize allowed customers once
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

    ----------------------------------------------------------------------
    -- De-duplicated Customer Master
    ----------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#DedupMaster') IS NOT NULL
        DROP TABLE #DedupMaster;

    CREATE TABLE #DedupMaster
    (
        CompanyCode  BIGINT        NOT NULL,
        CustomerCode NVARCHAR(50)  NOT NULL,
        CustomerName NVARCHAR(200) NULL,
        CONSTRAINT PK_#DedupMaster
            PRIMARY KEY (CompanyCode, CustomerCode)
    );

    INSERT INTO #DedupMaster
    (
        CompanyCode,
        CustomerCode,
        CustomerName
    )
    SELECT
        CompanyCode,
        CustomerCode,
        MIN(CustomerName) AS CustomerName
    FROM dbo.TB_CustomerMaster
    WHERE CustomerCode IS NOT NULL
      AND LTRIM(RTRIM(CustomerCode)) <> ''
      AND CompanyCode IS NOT NULL
    GROUP BY
        CompanyCode,
        CustomerCode;

    ----------------------------------------------------------------------
    -- 1) Grid
    ----------------------------------------------------------------------
    SELECT
        L.CompanyCode,
        L.CustomerCode,
        M.CustomerName,

        -- AB is kept in DB but shown as OP to the UI
        CASE
            WHEN L.Document_Type = 'AB' THEN 'OP'
            ELSE L.Document_Type
        END AS Document_Type,

        L.Document_Number,
        L.Credit_Control_Area,
        L.Document_Date,
        L.Net_Due_Date,
        L.Posting_Date,
        L.Arrears_by_Net_Due_Date,
        L.Credit_Control_Area_Currency,
        L.Baseline_Payment_Date,
        L.Amount_in_Local_Currency,

        -- Display values remain based on SAP D/C indicator.
        -- AB/OP is excluded from Debit/Credit TOTAL calculation
        -- in Get_All_DEBIT_CREDIT_TOTAL_NEW_1054.
        CASE
            WHEN L.DC = 'S' THEN L.Amount_in_Local_Currency
            ELSE 0
        END AS DebitAmount,

        CASE
            WHEN L.DC = 'H' THEN L.Amount_in_Local_Currency
            ELSE 0
        END AS CreditAmount,

        L.DC,
        L.Clearing_Date,
        L.Clearing_Document,
        L.Assignment,
        L.Reference,
        L.Text,
        L.Account,
        L.Document_Header_Text,
        L.UserCode,
        L.GLAccount
    FROM dbo.TB_CustomerLedger AS L
    LEFT JOIN #DedupMaster AS M
        ON M.CompanyCode = L.CompanyCode
       AND M.CustomerCode = L.CustomerCode
    WHERE L.CompanyCode = @CompanyCode
      AND @CompanyCode = 1054
      AND
      (
          @CreditControlArea IS NULL
          OR L.Credit_Control_Area = @CreditControlArea
      )
      AND L.Document_Date >= @FromDate
      AND L.Document_Date < @ToDateNextDay
      AND L.Document_Type IN ('RV', 'DC', 'DZ', 'AB')
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
      AND
      (
          @Document_Type IS NULL
          OR L.Document_Type = @Document_Type
      )
    ORDER BY
        ISNULL(L.Document_Date, '19000101') DESC,
        L.Document_Number DESC
    OFFSET @Offset ROWS
    FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    ----------------------------------------------------------------------
    -- 2) Total count
    -- AB must be included because it is included in the grid.
    ----------------------------------------------------------------------
    SELECT
        COUNT(1) AS TotalRecords
    FROM dbo.TB_CustomerLedger AS L
    WHERE L.CompanyCode = @CompanyCode
      AND @CompanyCode = 1054
      AND
      (
          @CreditControlArea IS NULL
          OR L.Credit_Control_Area = @CreditControlArea
      )
      AND L.Document_Date >= @FromDate
      AND L.Document_Date < @ToDateNextDay
      AND L.Document_Type IN ('RV', 'DC', 'DZ', 'AB')
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
      AND
      (
          @Document_Type IS NULL
          OR L.Document_Type = @Document_Type
      );

    ----------------------------------------------------------------------
    -- 3) Customers for dropdown
    -- Include AB customers also.
    ----------------------------------------------------------------------
    SELECT TOP (200)
        L.CustomerCode,
        COALESCE(M.CustomerName, L.CustomerCode) AS CustomerName
    FROM dbo.TB_CustomerLedger AS L
    LEFT JOIN #DedupMaster AS M
        ON M.CompanyCode = L.CompanyCode
       AND M.CustomerCode = L.CustomerCode
    WHERE L.CompanyCode = @CompanyCode
      AND @CompanyCode = 1054
      AND
      (
          @CreditControlArea IS NULL
          OR L.Credit_Control_Area = @CreditControlArea
      )
      AND L.Document_Date >= @FromDate
      AND L.Document_Date < @ToDateNextDay
      AND L.Document_Type IN ('RV', 'DC', 'DZ', 'AB')
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
      )
    GROUP BY
        L.CustomerCode,
        M.CustomerName
    ORDER BY
        L.CustomerCode
    OPTION (RECOMPILE);
END
GO
