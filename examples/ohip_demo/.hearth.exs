# Oracle publishes OHIP's Block (blk) and Event Management (evm) APIs as
# separate Swagger 2.0 specs. The registry pins each version to the
# commit of its release tag. `sources:` merges both into one integration.
# The specs declare no security scheme, only `authorization` as a header
# parameter, so the patches add a bearer scheme; `headers:` sends the
# other two headers every operation requires. They have no host either:
# each customer has its own gateway.
#
# Per hotel, nothing comes from config: `OhipDemo.Tenancy` resolves the
# token and the gateway from the `hotel:` each call passes, and every
# call passes `hotel_id:` for `x-hotelid`. Only the app key is config
# (OHIP_APP_KEY). `mix hearth.gen` keeps all of this and fills in the
# rest of the entry.
[
  registry: %{
    "ohip_blk" => %{
      "26.2" =>
        "https://raw.githubusercontent.com/oracle/hospitality-api-docs/52ca1813e050980441a8a9988d0ced3d209698e4/rest-api-specs/property/v1/blk.json",
      "26.3" =>
        "https://raw.githubusercontent.com/oracle/hospitality-api-docs/dd631fbd5d0fce74a7dbdf96b43f07ce587211f2/rest-api-specs/property/v1/blk.json"
    },
    "ohip_evm" => %{
      "26.2" =>
        "https://raw.githubusercontent.com/oracle/hospitality-api-docs/52ca1813e050980441a8a9988d0ced3d209698e4/rest-api-specs/property/v1/evm.json",
      "26.3" =>
        "https://raw.githubusercontent.com/oracle/hospitality-api-docs/dd631fbd5d0fce74a7dbdf96b43f07ce587211f2/rest-api-specs/property/v1/evm.json"
    }
  },
  integrations: [
    ohip: [
      module: OhipDemo.Integrations.Ohip,
      sources: [blk: "ohip_blk@26.2", evm: "ohip_evm@26.2"],
      source_sha256: [
        blk: "c094a6ed2f10c9f2930fb05f34213b3e337fac6917beec1b3a1edab504e2b8d5",
        evm: "68768aa791c01f35c3e05a42e4069eb585485b372c2669da66892c38cd17cae6"
      ],
      overrides: [
        patches: %{
          "/components/securitySchemes/bearerAuth" => %{"scheme" => "bearer", "type" => "http"},
          "/security" => [%{"bearerAuth" => []}]
        }
      ],
      headers: ["x-app-key": :app_key, "x-hotelid": [option: :hotel_id]],
      base_url: [resolve: {OhipDemo.Tenancy, :gateway}, options: [:hotel]],
      base_path: "",
      tags: [
        Block: [
          include: ["getBlocks", "getBlock", "getBlockRangeInfo", "getBlockRoomRateGrid"],
          exclude: [
            "postSubAllocation",
            "getBlockActivityLog",
            "getBlockWashInfo",
            "putBlockAllocationWash",
            "postBlockValidate",
            "getBlockDailyStatistics",
            "searchBlocks",
            "getNextBlockStatus",
            "putValidateBlockCode",
            "deleteAlternateDates",
            "postAlternateDates",
            "putAlternateDates",
            "getBlockAttachments",
            "deleteBlockAttachment",
            "deleteBlockAccessExclusion",
            "putBlockAccessExclusion",
            "putBlockCutoff",
            "deleteBlockOwners",
            "getBlockOwners",
            "postBlockOwners",
            "putBlockOwners",
            "putBlockRates",
            "getBlockReservations",
            "putBlockReservations",
            "deleteBlockRestriction",
            "getBlockRestrictions",
            "postBlockRestriction",
            "putClearAllRestrictions",
            "getBlockRevenueChanges",
            "putRoomTypeOrder",
            "getBlockRoomTypes",
            "postRoomingList",
            "getBlockRoomsStatus",
            "getBlockStatistics",
            "getBlockStatusChanges",
            "postTourSeries",
            "putTourSeriesValidate",
            "deleteBlockWashSchedules",
            "getBlockWashSchedules",
            "postBlockWashSchedules",
            "putBlockWashSchedules",
            "postCopyBlock",
            "putCateringStatus",
            "getCentralSalesHotels",
            "putContractDefaults",
            "getDefaultBlockCode",
            "postDefaultBlockCode",
            "postBlock",
            "getBlockDailyRevenue",
            "blockChangesByDateTime",
            "deleteBlock",
            "putBlock",
            "putBlockAllocation",
            "putBlockAllocationRange",
            "getBlockAvailability",
            "postCancelBlock",
            "putCateringRevenue",
            "getBlockExchangeInterfaces",
            "setBlockExchangeInterfaces",
            "putBlockStatusToOpen",
            "postBlockPostingMaster",
            "getBlockPMReservations",
            "changeRateOverride",
            "putRegularToMasterBlock",
            "putRegularToSubAllocation",
            "putRegularToSubTour",
            "putBlockShift",
            "putBlockStatus",
            "putSubBlockToRegular",
            "postSubBlock",
            "deleteBlockWashSchedule",
            "getBlockByExtId",
            "putBlockByExtId",
            "putBlockAllocationByExtId",
            "putBlockAllocationRangeByExtId",
            "getBlockPMReservationsByExtId",
            "putBlockStatusByExtId",
            "postSubBlockByExtId",
            "createPropertyLeads",
            "getTracesByDateRange",
            "putInventory",
            "putReleasedInventory",
            "getInventoryToBorrow",
            "getRecentlyAccessedBlocks",
            "getSalesAllowances",
            "pingBlockService"
          ]
        ],
        BlockStats: :none,
        BlockExternal: :none,
        EventManagement: [
          include: ["getEventCalendar", "getEventsOneHotel", "getEvent"],
          exclude: [
            "manageAlternateEvents",
            "getCateringPackages",
            "postCateringPackage",
            "changeCateringPackages",
            "copyCateringPackage",
            "getCateringPackageRevenue",
            "postCateringPackageRevenue",
            "copyEventResources",
            "moveEventResources",
            "getEventResourceByMenu",
            "cateringEventsBulkUpdate",
            "deleteCateringPackageRevenue",
            "changeCateringPackageRevenue",
            "changeEventResourceByMenu",
            "getEventCalendarMultipleHotelIds",
            "deleteMultipleEvents",
            "getEventsMultipleHotels",
            "postEvents",
            "getEventItemSplitQuantity",
            "changeEventsResourcesByChain",
            "getResourceEvents",
            "copyCateringEvents",
            "deleteCateringPackages",
            "deleteCateringPackage",
            "eventChangesByDateTime",
            "getCateringEventChanges",
            "deleteEvents",
            "changeEvents",
            "getCateringEventPostings",
            "manageCateringEventPostings",
            "postQuickInsertResources",
            "postMenuItemsToBookedMenu",
            "copyEventNotes",
            "getEventsResources",
            "changeEventsResources",
            "getBlockPostingAccountReservations",
            "getFunctionSpaceAvailability",
            "getSharedFunctionSpaceEvents",
            "getWaitlistedEvents",
            "manageWaitlistedEvents",
            "postOpportunityEvents",
            "pingEventManagementService"
          ]
        ]
      ],
      auth: [
        scheme: "bearerAuth",
        available: [bearerAuth: "bearer"],
        credential: [resolve: {OhipDemo.Tenancy, :token}, options: [:hotel]]
      ]
    ]
  ]
]
