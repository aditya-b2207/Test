ALTER PROCEDURE [dbo].[GetPendingSalesIndentList_MASL]
    @CompanyCode BIGINT,
    @UserCode NVARCHAR(50),
    @RoleId INT,
    @PageNumber INT = 1,
    @PageSize INT = 20
ASS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        ------------------------------------------------------------
        -- PAGINATION VALIDATION
        ------------------------------------------------------------
        IF @PageNumber IS NULL OR @PageNumber < 1
            SET @PageNumber = 1;

        IF @PageSize IS NULL OR @PageSize < 1
            SET @PageSize = 20;

        IF @PageSize > 100
            SET @PageSize = 100;


        ------------------------------------------------------------
        -- ELIGIBLE ORDERS
        ------------------------------------------------------------
        CREATE TABLE #EligibleOrders
        (
            CompanyCode BIGINT NOT NULL,
            CreateOrderNumber BIGINT NOT NULL,
            CartId BIGINT NOT NULL
        );


        ------------------------------------------------------------
        -- DEALER
        ------------------------------------------------------------
        IF @RoleId = 1
        BEGIN
            INSERT INTO #EligibleOrders
            (
                CompanyCode,
                CreateOrderNumber,
                CartId
            )
            SELECT
                CompanyCode,
                CreateOrderNumber,
                CartId
            FROM TB_Create_Dealer_Order
            WHERE CompanyCode = @CompanyCode
              AND UserCode = @UserCode
              AND SONumber IS NULL
              AND
              (
                    OrderRejectStatus = 0
                    OR OrderRejectStatus IS NULL
              );
        END


        ------------------------------------------------------------
        -- TM / RM / ZM
        ------------------------------------------------------------
        ELSE IF @RoleId IN (2,3,4)
        BEGIN
            INSERT INTO #EligibleOrders
            (
                CompanyCode,
                CreateOrderNumber,
                CartId
            )
            SELECT
                CompanyCode,
                CreateOrderNumber,
                CartId
            FROM TB_Create_Dealer_Order
            WHERE CompanyCode = @CompanyCode
              AND
              (
                    RepManCode = @UserCode
                    OR SecondApprovalUserCode = @UserCode
                    OR ZSMCode = @UserCode
              )
              AND SONumber IS NULL
              AND
              (
                    OrderRejectStatus = 0
                    OR OrderRejectStatus IS NULL
              );
        END


        ------------------------------------------------------------
        -- NSM / BHM / BA / FI / COMMERCIAL
        -- Current SP gives these roles company-wide pending records.
        ------------------------------------------------------------
        ELSE IF @RoleId IN (5,6,7,8,9)
        BEGIN
            INSERT INTO #EligibleOrders
            (
                CompanyCode,
                CreateOrderNumber,
                CartId
            )
            SELECT
                CompanyCode,
                CreateOrderNumber,
                CartId
            FROM TB_Create_Dealer_Order
            WHERE CompanyCode = @CompanyCode
              AND SONumber IS NULL
              AND
              (
                    OrderRejectStatus = 0
                    OR OrderRejectStatus IS NULL
              );
        END


        ------------------------------------------------------------
        -- TOTAL COUNT BEFORE PAGINATION
        ------------------------------------------------------------
        DECLARE @TotalRecords INT;

        SELECT
            @TotalRecords = COUNT(1)
        FROM #EligibleOrders;


        ------------------------------------------------------------
        -- CURRENT PAGE ORDERS
        ------------------------------------------------------------
        CREATE TABLE #PagedOrders
        (
            CompanyCode BIGINT NOT NULL,
            CreateOrderNumber BIGINT NOT NULL,
            CartId BIGINT NOT NULL
        );


        ;WITH RankedOrders AS
        (
            SELECT
                CompanyCode,
                CreateOrderNumber,
                CartId,

                ROW_NUMBER() OVER
                (
                    ORDER BY
                        CreateOrderNumber DESC,
                        CartId DESC
                ) AS RowNum

            FROM #EligibleOrders
        )

        INSERT INTO #PagedOrders
        (
            CompanyCode,
            CreateOrderNumber,
            CartId
        )
        SELECT
            CompanyCode,
            CreateOrderNumber,
            CartId
        FROM RankedOrders
        WHERE RowNum BETWEEN
              ((@PageNumber - 1) * @PageSize) + 1
              AND
              (@PageNumber * @PageSize);


        ------------------------------------------------------------
        -- RESULT SET 1:
        -- PAGED ORDER HEADERS
        ------------------------------------------------------------
        SELECT
            o.CompanyCode,
            o.CreateOrderNumber,
            o.DateOfPurchase,
            o.CartId,
            o.UserId,
            o.Total_Items,
            o.Total_Price,
            o.TMApproval,
            o.RMApproval,
            o.CustomerName,
            o.TMApproval_Date,
            o.RMApproval_Date,
            o.TMName,
            o.RMName,
            o.RepManCode,
            o.Email,
            o.SecondApprovalUserCode,
            o.SalesIndentStatus,
            o.OrderRejectStatus,
            o.UserCode,
            o.RMCode,
            o.ZSMCode,
            o.Approve_From_C_AND_F,
            o.Approve_From_Plant,
            o.NSMCode,
            o.NSMName,
            o.NSM_Approval,
            o.NSM_Approval_Date,
            o.BHM_Reporting_Code,
            o.BHMName,
            o.BHM_Approval,
            o.BHM_Approval_Date

        FROM TB_Create_Dealer_Order o

        INNER JOIN #PagedOrders p
            ON p.CompanyCode =
               o.CompanyCode

            AND p.CreateOrderNumber =
                o.CreateOrderNumber

            AND p.CartId =
                o.CartId

        ORDER BY
            o.CreateOrderNumber DESC;


        ------------------------------------------------------------
        -- RESULT SET 2:
        -- ITEMS ONLY FOR CURRENT PAGE
        ------------------------------------------------------------
        SELECT
            p.CreateOrderNumber,

            i.SrNo,
            i.Material_Description,
            i.Material_Code,

            ISNULL(
                Stock.Unrestricted_Kgs,
                0
            ) AS Stock,

            i.Quantity,
            i.Rate,
            i.Qty_Into_Rate_Amt,
            i.CartId,
            i.CartItemId

        FROM #PagedOrders p

        INNER JOIN TB_Cart_Items i
            ON p.CartId =
               i.CartId

            AND p.CompanyCode =
                i.CompanyCode

        INNER JOIN TB_Create_Dealer_Order o
            ON p.CreateOrderNumber =
               o.CreateOrderNumber

            AND p.CompanyCode =
                o.CompanyCode

        OUTER APPLY
        (
            SELECT TOP (1)
                ts.Unrestricted_Kgs

            FROM TB_StockDetails ts

            WHERE ts.CompanyCode =
                  o.CompanyCode

              AND LTRIM(RTRIM(ts.Material)) =
                  LTRIM(RTRIM(i.Material_Code))

            ORDER BY
                ts.Unrestricted_Kgs DESC
        ) Stock

        ORDER BY
            p.CreateOrderNumber DESC,
            i.SrNo;


        ------------------------------------------------------------
        -- RESULT SET 3:
        -- TOTAL RECORDS
        ------------------------------------------------------------
        SELECT
            @TotalRecords AS TotalRecords;


        DROP TABLE #PagedOrders;
        DROP TABLE #EligibleOrders;

    END TRY

    BEGIN CATCH

        IF OBJECT_ID('tempdb..#PagedOrders') IS NOT NULL
            DROP TABLE #PagedOrders;

        IF OBJECT_ID('tempdb..#EligibleOrders') IS NOT NULL
            DROP TABLE #EligibleOrders;


        DECLARE @ErrorMessage NVARCHAR(MAX) =
            ERROR_MESSAGE();

        DECLARE @ErrorSeverity INT =
            ERROR_SEVERITY();

        DECLARE @ErrorState INT =
            ERROR_STATE();

        DECLARE @ErrorLine INT =
            ERROR_LINE();

        DECLARE @ErrorProcedure NVARCHAR(200) =
            ERROR_PROCEDURE();


        INSERT INTO Error_Log
        (
            ErrorMessage,
            ErrorSeverity,
            ErrorState,
            ErrorLine,
            ErrorProcedure,
            ErrorDateTime
        )
        VALUES
        (
            @ErrorMessage,
            @ErrorSeverity,
            @ErrorState,
            @ErrorLine,
            @ErrorProcedure,
            GETDATE()
        );

        THROW;

    END CATCH;
END;
GO