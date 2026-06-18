# TxnRequest


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**database_id** | **str** |  | 
**operations** | [**List[TxnRequestOperationsInner]**](TxnRequestOperationsInner.md) |  | 

## Example

```python
from grobase.models.txn_request import TxnRequest

# TODO update the JSON string below
json = "{}"
# create an instance of TxnRequest from a JSON string
txn_request_instance = TxnRequest.from_json(json)
# print the JSON string representation of the object
print(TxnRequest.to_json())

# convert the object into a dict
txn_request_dict = txn_request_instance.to_dict()
# create an instance of TxnRequest from a dict
txn_request_from_dict = TxnRequest.from_dict(txn_request_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


