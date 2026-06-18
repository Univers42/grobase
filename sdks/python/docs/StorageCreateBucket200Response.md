# StorageCreateBucket200Response


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**name** | **str** |  | [optional] 
**created** | **bool** |  | [optional] 

## Example

```python
from grobase.models.storage_create_bucket200_response import StorageCreateBucket200Response

# TODO update the JSON string below
json = "{}"
# create an instance of StorageCreateBucket200Response from a JSON string
storage_create_bucket200_response_instance = StorageCreateBucket200Response.from_json(json)
# print the JSON string representation of the object
print(StorageCreateBucket200Response.to_json())

# convert the object into a dict
storage_create_bucket200_response_dict = storage_create_bucket200_response_instance.to_dict()
# create an instance of StorageCreateBucket200Response from a dict
storage_create_bucket200_response_from_dict = StorageCreateBucket200Response.from_dict(storage_create_bucket200_response_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


