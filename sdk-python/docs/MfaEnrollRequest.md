# MfaEnrollRequest


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**factor_type** | **str** |  | [optional] [default to 'totp']
**friendly_name** | **str** |  | [optional] 
**issuer** | **str** |  | [optional] 
**phone** | **str** |  | [optional] 

## Example

```python
from grobase.models.mfa_enroll_request import MfaEnrollRequest

# TODO update the JSON string below
json = "{}"
# create an instance of MfaEnrollRequest from a JSON string
mfa_enroll_request_instance = MfaEnrollRequest.from_json(json)
# print the JSON string representation of the object
print(MfaEnrollRequest.to_json())

# convert the object into a dict
mfa_enroll_request_dict = mfa_enroll_request_instance.to_dict()
# create an instance of MfaEnrollRequest from a dict
mfa_enroll_request_from_dict = MfaEnrollRequest.from_dict(mfa_enroll_request_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


