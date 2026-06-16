# StorageObject


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**key** | **str** |  | [optional] 
**size** | **int** |  | [optional] 
**last_modified** | **str** |  | [optional] 
**etag** | **str** |  | [optional] 

## Example

```python
from grobase.models.storage_object import StorageObject

# TODO update the JSON string below
json = "{}"
# create an instance of StorageObject from a JSON string
storage_object_instance = StorageObject.from_json(json)
# print the JSON string representation of the object
print(StorageObject.to_json())

# convert the object into a dict
storage_object_dict = storage_object_instance.to_dict()
# create an instance of StorageObject from a dict
storage_object_from_dict = StorageObject.from_dict(storage_object_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


