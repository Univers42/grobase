# SignedUrl


## Properties

Name | Type | Description | Notes
------------ | ------------- | ------------- | -------------
**signed_url** | **str** |  | [optional] 
**expires_at** | **str** |  | [optional] 
**method** | **str** |  | [optional] 
**bucket** | **str** |  | [optional] 
**key** | **str** |  | [optional] 

## Example

```python
from grobase.models.signed_url import SignedUrl

# TODO update the JSON string below
json = "{}"
# create an instance of SignedUrl from a JSON string
signed_url_instance = SignedUrl.from_json(json)
# print the JSON string representation of the object
print(SignedUrl.to_json())

# convert the object into a dict
signed_url_dict = signed_url_instance.to_dict()
# create an instance of SignedUrl from a dict
signed_url_from_dict = SignedUrl.from_dict(signed_url_dict)
```
[[Back to Model list]](../README.md#documentation-for-models) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to README]](../README.md)


