# MfaEnrollResponse


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**id** | **str** |  | 
**type** | **str** |  | 
**friendly_name** | **str** |  | [optional] 
**totp** | [**MfaEnrollResponseTotp**](MfaEnrollResponseTotp.md) |  | [optional] 

## Example

```python
from grobase.models.mfa_enroll_response import MfaEnrollResponse

# TODO update the JSON string below
json = "{}"
# create an instance of MfaEnrollResponse from a JSON string
mfa_enroll_response_instance = MfaEnrollResponse.from_json(json)
# print the JSON string representation of the object
print(MfaEnrollResponse.to_json())

# convert the object into a dict
mfa_enroll_response_dict = mfa_enroll_response_instance.to_dict()
# create an instance of MfaEnrollResponse from a dict
mfa_enroll_response_from_dict = MfaEnrollResponse.from_dict(mfa_enroll_response_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


