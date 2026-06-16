
# TxnRequestOperationsInner

## Properties
| Name | Type | Description | Notes |
| ------------ | ------------- | ------------- | ------------- |
| **op** | [**inline**](#Op) |  |  |
| **resource** | **kotlin.String** |  |  |
| **&#x60;data&#x60;** | [**kotlin.collections.Map&lt;kotlin.String, kotlin.Any&gt;**](kotlin.Any.md) |  |  [optional] |
| **filter** | [**kotlin.collections.Map&lt;kotlin.String, kotlin.Any&gt;**](kotlin.Any.md) |  |  [optional] |
| **idempotencyKey** | **kotlin.String** |  |  [optional] |


<a id="Op"></a>
## Enum: op
| Name | Value |
| ---- | ----- |
| op | insert, update, delete, upsert |



