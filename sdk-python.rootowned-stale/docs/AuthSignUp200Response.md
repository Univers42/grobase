# AuthSignUp200Response


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**access_token** | **str** |  | 
**token_type** | **str** |  | [optional] 
**expires_in** | **int** |  | [optional] 
**expires_at** | **int** |  | [optional] 
**refresh_token** | **str** |  | [optional] 
**user** | [**User**](User.md) |  | [optional] 
**id** | **UUID** |  | 
**email** | **str** |  | [optional] 
**role** | **str** |  | [optional] 
**aud** | **str** |  | [optional] 
**app_metadata** | **Dict[str, object]** |  | [optional] 
**user_metadata** | **Dict[str, object]** |  | [optional] 
**created_at** | **datetime** |  | [optional] 

## Example

```python
from grobase.models.auth_sign_up200_response import AuthSignUp200Response

# TODO update the JSON string below
json = "{}"
# create an instance of AuthSignUp200Response from a JSON string
auth_sign_up200_response_instance = AuthSignUp200Response.from_json(json)
# print the JSON string representation of the object
print(AuthSignUp200Response.to_json())

# convert the object into a dict
auth_sign_up200_response_dict = auth_sign_up200_response_instance.to_dict()
# create an instance of AuthSignUp200Response from a dict
auth_sign_up200_response_from_dict = AuthSignUp200Response.from_dict(auth_sign_up200_response_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


