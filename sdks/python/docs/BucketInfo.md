# BucketInfo


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**name** | **str** |  | [optional] 
**created_at** | **str** |  | [optional] 

## Example

```python
from grobase.models.bucket_info import BucketInfo

# TODO update the JSON string below
json = "{}"
# create an instance of BucketInfo from a JSON string
bucket_info_instance = BucketInfo.from_json(json)
# print the JSON string representation of the object
print(BucketInfo.to_json())

# convert the object into a dict
bucket_info_dict = bucket_info_instance.to_dict()
# create an instance of BucketInfo from a dict
bucket_info_from_dict = BucketInfo.from_dict(bucket_info_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


