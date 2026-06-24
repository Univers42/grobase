import React, { useState } from 'react';
import { View, StyleSheet, ViewStyle } from 'react-native';
import { TextInput, HelperText, useTheme } from 'react-native-paper';

interface FormInputProps {
  label: string;
  value: string;
  onChangeText: (text: string) => void;
  error?: string | null;
  touched?: boolean;
  placeholder?: string;
  secureTextEntry?: boolean;
  autoCapitalize?: 'none' | 'sentences' | 'words' | 'characters';
  keyboardType?: 'default' | 'email-address' | 'numeric' | 'phone-pad';
  maxLength?: number;
  multiline?: boolean;
  numberOfLines?: number;
  left?: React.ReactNode;
  right?: React.ReactNode;
  disabled?: boolean;
  onBlur?: () => void;
  style?: ViewStyle;
  testID?: string;
}

export const FormInput: React.FC<FormInputProps> = ({
  label,
  value,
  onChangeText,
  error,
  touched = false,
  placeholder,
  secureTextEntry = false,
  autoCapitalize = 'none',
  keyboardType = 'default',
  maxLength,
  multiline = false,
  numberOfLines = 1,
  left,
  right,
  disabled = false,
  onBlur,
  style,
  testID,
}) => {
  const [isSecureVisible, setIsSecureVisible] = useState(!secureTextEntry);
  const showError = touched && error;

  return (
    <View style={[styles.container, style]}>
      <TextInput
        label={label}
        value={value}
        onChangeText={onChangeText}
        placeholder={placeholder}
        secureTextEntry={secureTextEntry && !isSecureVisible}
        autoCapitalize={autoCapitalize}
        keyboardType={keyboardType}
        maxLength={maxLength}
        multiline={multiline}
        numberOfLines={numberOfLines}
        left={left}
        right={
          secureTextEntry ? (
            <TextInput.Icon
              icon={isSecureVisible ? 'eye-off' : 'eye'}
              onPress={() => setIsSecureVisible(!isSecureVisible)}
              accessibilityLabel={isSecureVisible ? 'Hide password' : 'Show password'}
            />
          ) : (
            right
          )
        }
        disabled={disabled}
        onBlur={onBlur}
        error={!!showError}
        mode="outlined"
        testID={testID}
        accessibilityLabel={label}
        accessibilityHint={error || undefined}
      />
      {showError && (
        <HelperText type="error" visible={true}>
          {error}
        </HelperText>
      )}
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    marginBottom: 12,
  },
});
