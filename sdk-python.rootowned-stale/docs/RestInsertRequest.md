# RestInsertRequest


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------

## Example

```python
from grobase.models.rest_insert_request import RestInsertRequest

# TODO update the JSON string below
json = "{}"
# create an instance of RestInsertRequest from a JSON string
rest_insert_request_instance = RestInsertRequest.from_json(json)
# print the JSON string representation of the object
print(RestInsertRequest.to_json())

# convert the object into a dict
rest_insert_request_dict = rest_insert_request_instance.to_dict()
# create an instance of RestInsertRequest from a dict
rest_insert_request_from_dict = RestInsertRequest.from_dict(rest_insert_request_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


