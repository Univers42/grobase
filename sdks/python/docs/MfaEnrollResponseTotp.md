# MfaEnrollResponseTotp


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**qr_code** | **str** |  | [optional] 
**secret** | **str** |  | [optional] 
**uri** | **str** |  | [optional] 

## Example

```python
from grobase.models.mfa_enroll_response_totp import MfaEnrollResponseTotp

# TODO update the JSON string below
json = "{}"
# create an instance of MfaEnrollResponseTotp from a JSON string
mfa_enroll_response_totp_instance = MfaEnrollResponseTotp.from_json(json)
# print the JSON string representation of the object
print(MfaEnrollResponseTotp.to_json())

# convert the object into a dict
mfa_enroll_response_totp_dict = mfa_enroll_response_totp_instance.to_dict()
# create an instance of MfaEnrollResponseTotp from a dict
mfa_enroll_response_totp_from_dict = MfaEnrollResponseTotp.from_dict(mfa_enroll_response_totp_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


