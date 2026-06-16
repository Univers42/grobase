# TxnResponseResultsInner


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**op** | **str** |  | [optional] 
**resource** | **str** |  | [optional] 
**row_count** | **int** |  | [optional] 

## Example

```python
from grobase.models.txn_response_results_inner import TxnResponseResultsInner

# TODO update the JSON string below
json = "{}"
# create an instance of TxnResponseResultsInner from a JSON string
txn_response_results_inner_instance = TxnResponseResultsInner.from_json(json)
# print the JSON string representation of the object
print(TxnResponseResultsInner.to_json())

# convert the object into a dict
txn_response_results_inner_dict = txn_response_results_inner_instance.to_dict()
# create an instance of TxnResponseResultsInner from a dict
txn_response_results_inner_from_dict = TxnResponseResultsInner.from_dict(txn_response_results_inner_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


