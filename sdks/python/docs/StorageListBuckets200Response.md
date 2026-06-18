# StorageListBuckets200Response


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**buckets** | [**List[BucketInfo]**](BucketInfo.md) |  | [optional] 

## Example

```python
from grobase.models.storage_list_buckets200_response import StorageListBuckets200Response

# TODO update the JSON string below
json = "{}"
# create an instance of StorageListBuckets200Response from a JSON string
storage_list_buckets200_response_instance = StorageListBuckets200Response.from_json(json)
# print the JSON string representation of the object
print(StorageListBuckets200Response.to_json())

# convert the object into a dict
storage_list_buckets200_response_dict = storage_list_buckets200_response_instance.to_dict()
# create an instance of StorageListBuckets200Response from a dict
storage_list_buckets200_response_from_dict = StorageListBuckets200Response.from_dict(storage_list_buckets200_response_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


