# TxnRequestOperationsInner


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**op** | **str** |  | 
**resource** | **str** |  | 
**data** | **Dict[str, object]** |  | [optional] 
**filter** | **Dict[str, object]** |  | [optional] 
**idempotency_key** | **str** |  | [optional] 

## Example

```python
from grobase.models.txn_request_operations_inner import TxnRequestOperationsInner

# TODO update the JSON string below
json = "{}"
# create an instance of TxnRequestOperationsInner from a JSON string
txn_request_operations_inner_instance = TxnRequestOperationsInner.from_json(json)
# print the JSON string representation of the object
print(TxnRequestOperationsInner.to_json())

# convert the object into a dict
txn_request_operations_inner_dict = txn_request_operations_inner_instance.to_dict()
# create an instance of TxnRequestOperationsInner from a dict
txn_request_operations_inner_from_dict = TxnRequestOperationsInner.from_dict(txn_request_operations_inner_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


