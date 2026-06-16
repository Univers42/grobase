# TxnResponse


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**guarantee** | **str** |  | [optional] 
**mount** | **str** |  | [optional] 
**results** | [**List[TxnResponseResultsInner]**](TxnResponseResultsInner.md) |  | [optional] 

## Example

```python
from grobase.models.txn_response import TxnResponse

# TODO update the JSON string below
json = "{}"
# create an instance of TxnResponse from a JSON string
txn_response_instance = TxnResponse.from_json(json)
# print the JSON string representation of the object
print(TxnResponse.to_json())

# convert the object into a dict
txn_response_dict = txn_response_instance.to_dict()
# create an instance of TxnResponse from a dict
txn_response_from_dict = TxnResponse.from_dict(txn_response_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


