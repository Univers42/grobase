# AuthRecoverRequest


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**email** | **str** |  | 

## Example

```python
from grobase.models.auth_recover_request import AuthRecoverRequest

# TODO update the JSON string below
json = "{}"
# create an instance of AuthRecoverRequest from a JSON string
auth_recover_request_instance = AuthRecoverRequest.from_json(json)
# print the JSON string representation of the object
print(AuthRecoverRequest.to_json())

# convert the object into a dict
auth_recover_request_dict = auth_recover_request_instance.to_dict()
# create an instance of AuthRecoverRequest from a dict
auth_recover_request_from_dict = AuthRecoverRequest.from_dict(auth_recover_request_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


