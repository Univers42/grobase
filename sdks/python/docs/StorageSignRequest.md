# StorageSignRequest


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**method** | **str** |  | [optional] 
**expires_in** | **int** |  | [optional] 
**content_type** | **str** |  | [optional] 

## Example

```python
from grobase.models.storage_sign_request import StorageSignRequest

# TODO update the JSON string below
json = "{}"
# create an instance of StorageSignRequest from a JSON string
storage_sign_request_instance = StorageSignRequest.from_json(json)
# print the JSON string representation of the object
print(StorageSignRequest.to_json())

# convert the object into a dict
storage_sign_request_dict = storage_sign_request_instance.to_dict()
# create an instance of StorageSignRequest from a dict
storage_sign_request_from_dict = StorageSignRequest.from_dict(storage_sign_request_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


